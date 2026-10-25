// build-static-deps.sh's check of libusbmuxd-inetcat-writes.patch, run against the inetcat just built. A stand-in
// usbmuxd on a Unix socket lists one USB device, accepts the connect and then reads the stream a page at a time, so
// inetcat's non-blocking socket fills and its writes come back short or with EAGAIN. Two cases:
// - upload: everything inetcat reads from stdin reaches the device's port, in order.
// - both ways: the port first sends 4 MiB without reading, as a device that answers while the host still sends does.
//   inetcat has to keep reading the port while its upload waits, and both streams arrive whole and in order.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define UPLOAD_BYTES (1 << 20)
#define DOWNLOAD_BYTES (4 << 20)

struct header { // usbmuxd's message header, in host byte order
    uint32_t length, version, message, tag;
};

static const char *devices =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>DeviceList</key><array><dict>"
    "<key>DeviceID</key><integer>1</integer><key>MessageType</key><string>Attached</string>"
    "<key>Properties</key><dict><key>ConnectionType</key><string>USB</string><key>DeviceID</key><integer>1</integer>"
    "<key>LocationID</key><integer>1</integer><key>ProductID</key><integer>4761</integer>"
    "<key>SerialNumber</key><string>0000000000000000000000000000000000000001</string></dict></dict></array></dict>"
    "</plist>";
static const char *connected = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist "
                               "version=\"1.0\"><dict><key>MessageType</key><string>Result</string>"
                               "<key>Number</key><integer>0</integer></dict></plist>";

static int read_all(int fd, void *buffer, size_t size) {
    for (size_t done = 0; done < size;) {
        ssize_t n = read(fd, (char *)buffer + done, size - done);
        if (n <= 0)
            return -1;
        done += (size_t)n;
    }
    return 0;
}

static int answer(int listener, const char *plist) // one client: read its request, reply with the plist and its tag
{
    int fd = accept(listener, NULL, NULL);
    struct header request;
    if (fd < 0 || read_all(fd, &request, sizeof(request)) != 0 || request.length < sizeof(request))
        return -1;
    char *body = malloc(request.length - sizeof(request) + 1);
    int read = read_all(fd, body, request.length - sizeof(request));
    free(body);
    struct header reply = {(uint32_t)(sizeof(reply) + strlen(plist)), 1, 8, request.tag};
    if (read != 0 || write(fd, &reply, sizeof(reply)) != sizeof(reply) ||
        write(fd, plist, strlen(plist)) != (ssize_t)strlen(plist))
        return -1;
    return fd;
}

static uint8_t expected(size_t offset) // a position-dependent pattern, so a dropped or repeated page shows
{
    return (uint8_t)((offset >> 12) * 31 + offset);
}

static int run(const char *inetcat, const char *directory, int both) // 0 when every stream arrived whole, in order
{
    const char *name = both ? "both ways" : "upload";
    char input[PATH_MAX], output[PATH_MAX], address[PATH_MAX];
    snprintf(input, sizeof(input), "%s/in", directory);
    snprintf(output, sizeof(output), "%s/out", directory);
    snprintf(address, sizeof(address), "%s/usbmuxd", directory);
    int in = open(input, O_RDWR | O_CREAT | O_TRUNC, 0600), out = open(output, O_RDWR | O_CREAT | O_TRUNC, 0600);
    uint8_t *data = malloc(DOWNLOAD_BYTES);
    for (size_t i = 0; i < DOWNLOAD_BYTES; i++)
        data[i] = expected(i);
    if (in < 0 || out < 0 || write(in, data, UPLOAD_BYTES) != UPLOAD_BYTES || lseek(in, 0, SEEK_SET) != 0)
        return 2;

    struct sockaddr_un socket_name = {.sun_family = AF_UNIX};
    strlcpy(socket_name.sun_path, address, sizeof(socket_name.sun_path));
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&socket_name, sizeof(socket_name)) != 0 ||
        listen(listener, 4) != 0)
        return 2;

    pid_t child = fork();
    if (child == 0) {
        char variable[PATH_MAX + 32];
        snprintf(variable, sizeof(variable), "USBMUXD_SOCKET_ADDRESS=UNIX:%s", address);
        putenv(variable);
        dup2(in, STDIN_FILENO);
        dup2(out, STDOUT_FILENO);
        execl(inetcat, inetcat, "22", (char *)NULL);
        _exit(127);
    }
    close(in);
    int list = answer(listener, devices);
    int stream = list < 0 ? -1 : answer(listener, connected);
    const char *failure = NULL;
    struct timeval limit = {10, 0}; // a stalled stream fails the check instead of hanging the build
    if (stream >= 0 && (setsockopt(stream, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit)) != 0 ||
                        setsockopt(stream, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit)) != 0))
        return 2;
    for (size_t sent = 0; stream >= 0 && both && sent < DOWNLOAD_BYTES;) {
        ssize_t n = write(stream, data + sent, DOWNLOAD_BYTES - sent);
        if (n <= 0) {
            failure = errno == EAGAIN ? "stopped reading the port while its upload waited, 10 s with no progress"
                                      : "closed the port before it read the download";
            break;
        }
        sent += (size_t)n;
    }
    size_t received = 0, wrong = SIZE_MAX;
    uint8_t page[4096];
    ssize_t n = 0;
    while (stream >= 0 && !failure && (n = read(stream, page, sizeof(page))) > 0) {
        for (ssize_t i = 0; i < n && wrong == SIZE_MAX; i++)
            if (received + (size_t)i >= UPLOAD_BYTES || page[i] != data[received + (size_t)i])
                wrong = received + (size_t)i;
        received += (size_t)n;
        usleep(2000); // slower than inetcat reads its stdin
    }
    if (n < 0 && !failure)
        failure = "stopped sending its upload, 10 s with no progress";
    if (failure)
        kill(child, SIGKILL);
    if (stream >= 0)
        close(stream);
    int status = 0;
    waitpid(child, &status, 0);
    close(listener);
    size_t downloaded = 0, download_wrong = SIZE_MAX;
    uint8_t *copy = malloc(DOWNLOAD_BYTES);
    ssize_t length = pread(out, copy, DOWNLOAD_BYTES, 0);
    for (; length > 0 && downloaded < (size_t)length; downloaded++)
        if (download_wrong == SIZE_MAX && copy[downloaded] != data[downloaded])
            download_wrong = downloaded;
    free(copy);
    free(data);
    close(out);
    unlink(input);
    unlink(output);
    unlink(address);

    if (list < 0 || stream < 0) {
        fprintf(stderr, "%s: inetcat did not list and connect through the stand-in usbmuxd (status %d)\n", name,
                status);
        return 1;
    }
    if (failure) {
        fprintf(stderr, "%s: inetcat %s: libusbmuxd-inetcat-writes.patch is not in effect\n", name, failure);
        return 1;
    }
    if (wrong != SIZE_MAX) {
        fprintf(stderr,
                "%s: inetcat's upload is wrong from byte %zu: libusbmuxd-inetcat-writes.patch is not in effect\n", name,
                wrong);
        return 1;
    }
    if (received != UPLOAD_BYTES) {
        fprintf(stderr, "%s: inetcat delivered %zu of %d bytes: libusbmuxd-inetcat-writes.patch is not in effect\n",
                name, received, UPLOAD_BYTES);
        return 1;
    }
    if (both && (download_wrong != SIZE_MAX || downloaded != DOWNLOAD_BYTES)) {
        fprintf(stderr, "%s: inetcat wrote %zu of %d bytes to stdout, wrong from byte %zd\n", name, downloaded,
                DOWNLOAD_BYTES, download_wrong == SIZE_MAX ? (ssize_t)-1 : (ssize_t)download_wrong);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: inetcat-writes INETCAT\n");
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    alarm(120);
    char directory[] = "/tmp/inetcat-writes.XXXXXX";
    if (!mkdtemp(directory))
        return 2;
    int upload = run(argv[1], directory, 0);
    int both = run(argv[1], directory, 1);
    rmdir(directory);
    return upload != 0 ? upload : both;
}
