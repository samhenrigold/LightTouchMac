/*
 * lockdown-mcinstall <certificate.der>
 * lockdown-mcinstall --installed
 *
 * Offer the device a configuration profile that trusts one root certificate
 * (the per-device web proxy CA, WebProxyCA), through lockdown's
 * stock com.apple.mobile.MCInstall service: what iPhone Configuration Utility
 * did. The device shows "Install Profile" in Settings and the user confirms it
 * once; nothing is trusted without that tap. Reinstalling replaces the profile
 * (same identifier). The app's first choice is the guest agent (ittrust, no
 * screen); this is the fallback for a guest without one.
 *
 * --installed asks GetProfileList and exits 0 when the profile is installed
 * (3 when it is not), so the app never offers it twice.
 *
 * A separate process like lockdown-tz, for the same reason: lockdown writes
 * made in-process from the app have corrupted its heap. Finds the device via
 * USBMUXD_SOCKET_ADDRESS. Exits 0 when the device acknowledges the request.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/property_list_service.h>
#include <plist/plist.h>

#define PROFILE_ID "com.lighttouch.webproxy"

static plist_t payload(const char *type, const char *id, const char *uuid, const char *name)
{
    plist_t p = plist_new_dict();
    plist_dict_set_item(p, "PayloadType", plist_new_string(type));
    plist_dict_set_item(p, "PayloadVersion", plist_new_uint(1));
    plist_dict_set_item(p, "PayloadIdentifier", plist_new_string(id));
    plist_dict_set_item(p, "PayloadUUID", plist_new_string(uuid));
    plist_dict_set_item(p, "PayloadDisplayName", plist_new_string(name));
    plist_dict_set_item(p, "PayloadOrganization", plist_new_string("Light Touch"));
    return p;
}

int main(int argc, char **argv)
{
    idevice_t dev = NULL;
    lockdownd_client_t ld = NULL;
    lockdownd_service_descriptor_t svc = NULL;
    property_list_service_client_t pl = NULL;
    char *cert = NULL, *xml = NULL, *status = NULL;
    uint32_t xml_len = 0;
    long n;
    FILE *f;

    int query = argc == 2 && !strcmp(argv[1], "--installed");
    if (argc != 2) {
        fprintf(stderr, "usage: lockdown-mcinstall <certificate.der> | --installed\n");
        return 2;
    }
    if (!query && (!(f = fopen(argv[1], "rb")) || fseek(f, 0, SEEK_END) || (n = ftell(f)) <= 0 || n > (1 << 20))) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        return 2;
    }
    if (!query) {
        rewind(f);
        cert = malloc(n);
        if (fread(cert, 1, n, f) != (size_t)n) {
            fprintf(stderr, "cannot read %s\n", argv[1]);
            return 2;
        }
        fclose(f);
    }

    if (idevice_new(&dev, NULL) != IDEVICE_E_SUCCESS ||
        lockdownd_client_new_with_handshake(dev, &ld, "lockdown-mcinstall") != LOCKDOWN_E_SUCCESS ||
        lockdownd_start_service(ld, "com.apple.mobile.MCInstall", &svc) != LOCKDOWN_E_SUCCESS ||
        property_list_service_client_new(dev, svc, &pl) != PROPERTY_LIST_SERVICE_E_SUCCESS) {
        fprintf(stderr, "cannot reach the device's MCInstall service\n");
        return 1;
    }
    if (query) {
        /* iOS 3 and 4 answer OrderedIdentifiers (an array) and/or ProfileMetadata (a dict by identifier). */
        plist_t req = plist_new_dict(), resp = NULL;
        plist_dict_set_item(req, "RequestType", plist_new_string("GetProfileList"));
        if (property_list_service_send_xml_plist(pl, req) != PROPERTY_LIST_SERVICE_E_SUCCESS ||
            property_list_service_receive_plist(pl, &resp) != PROPERTY_LIST_SERVICE_E_SUCCESS || !resp) {
            fprintf(stderr, "MCInstall did not answer\n");
            return 1;
        }
        int found = 0;
        plist_t meta = plist_dict_get_item(resp, "ProfileMetadata");
        if (meta && plist_get_node_type(meta) == PLIST_DICT && plist_dict_get_item(meta, PROFILE_ID))
            found = 1;
        plist_t ids = plist_dict_get_item(resp, "OrderedIdentifiers");
        if (ids && plist_get_node_type(ids) == PLIST_ARRAY) {
            uint32_t i, count = plist_array_get_size(ids);
            for (i = 0; i < count && !found; i++) {
                char *id = NULL;
                plist_get_string_val(plist_array_get_item(ids, i), &id);
                if (id && !strcmp(id, PROFILE_ID)) found = 1;
                free(id);
            }
        }
        printf("%s\n", found ? "installed" : "not installed");
        return found ? 0 : 3;
    }

    /* Fixed identifiers and UUIDs: a new CA replaces the old profile instead of piling up. */
    plist_t root = payload("com.apple.security.root", PROFILE_ID ".ca",
                           "5F1A7C3E-9D2B-4E61-8A0F-4C54504341AA", "Light Touch Web Proxy CA");
    plist_dict_set_item(root, "PayloadContent", plist_new_data(cert, n));
    plist_t profile = payload("Configuration", PROFILE_ID,
                              "5F1A7C3E-9D2B-4E61-8A0F-4C5450524F46", "Light Touch Web Proxy");
    plist_dict_set_item(profile, "PayloadDescription", plist_new_string(
        "Lets Safari open secure sites through Light Touch's web proxy. Trusts this device's own proxy certificate."));
    plist_t content = plist_new_array();
    plist_array_append_item(content, root);
    plist_dict_set_item(profile, "PayloadContent", content);
    plist_to_xml(profile, &xml, &xml_len);

    plist_t req = plist_new_dict(), resp = NULL;
    plist_dict_set_item(req, "RequestType", plist_new_string("InstallProfile"));
    plist_dict_set_item(req, "Payload", plist_new_data(xml, xml_len));
    if (property_list_service_send_xml_plist(pl, req) != PROPERTY_LIST_SERVICE_E_SUCCESS ||
        property_list_service_receive_plist(pl, &resp) != PROPERTY_LIST_SERVICE_E_SUCCESS || !resp) {
        fprintf(stderr, "MCInstall did not answer\n");
        return 1;
    }
    plist_t s = plist_dict_get_item(resp, "Status");
    if (s)
        plist_get_string_val(s, &status);
    printf("%s\n", status ? status : "(no status)");
    return status && !strcmp(status, "Acknowledged") ? 0 : 1;
}
