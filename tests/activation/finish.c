/* Guest protocol contract, with real plist values and a deterministic lockdown. */
#define lockdownd_get_value fake_get
#define lockdownd_set_value fake_set
#define main helper_main
#include "../../scripts/lockdown-tz.c"
#undef main
#include <assert.h>

static plist_t values;
static int writes, fail_write, lose_write;
lockdownd_error_t fake_get(lockdownd_client_t client, const char *domain, const char *key, plist_t *out)
{
    (void)client; (void)domain;
    plist_t v = plist_dict_get_item(values, key);
    *out = v ? plist_copy(v) : NULL;
    return v ? LOCKDOWN_E_SUCCESS : LOCKDOWN_E_UNKNOWN_ERROR;
}
lockdownd_error_t fake_set(lockdownd_client_t client, const char *domain, const char *key, plist_t value)
{
    (void)client; (void)domain;
    writes++;
    if (fail_write) { plist_free(value); return LOCKDOWN_E_UNKNOWN_ERROR; }
    if (lose_write) { plist_free(value); return LOCKDOWN_E_SUCCESS; }
    plist_dict_set_item(values, key, value);
    if (!strcmp(key, "iTunesHasConnected"))
        plist_dict_set_item(values, "BrickState", plist_new_bool(0));
    return LOCKDOWN_E_SUCCESS;
}
static void fixture(const char *product, const char *version, const char *state)
{
    if (values) plist_free(values);
    values = plist_new_dict(); writes = fail_write = lose_write = 0;
    plist_dict_set_item(values, "ProductType", plist_new_string(product));
    plist_dict_set_item(values, "ProductVersion", plist_new_string(version));
    plist_dict_set_item(values, "ActivationState", plist_new_string(state));
}
int main(void)
{
    fixture("iPod2,1", "2.1.1", "Activated");
    plist_dict_set_item(values, "BrickState", plist_new_bool(1));
    assert(finish_activation(NULL) == 0 && writes == 1);
    assert(bool_value(NULL, "BrickState") == 0);
    assert(finish_activation(NULL) == 0 && writes == 1); // no repeated write
    assert(!plist_dict_get_item(values, "TimeIntervalSince1970"));
    fixture("iPad1,1", "5.1.1", "Activated");
    assert(finish_activation(NULL) == 0 && writes == 1);
    assert(bool_value(NULL, "ActivationStateAcknowledged") == 1);
    assert(!plist_dict_get_item(values, "iTunesHasConnected"));
    assert(finish_activation(NULL) == 0 && writes == 1);
    fixture("iPod2,1", "3.1.3", "Activated"); fail_write = 1;
    assert(finish_activation(NULL) == 5);
    fixture("iPad1,1", "5.1.1", "Activated"); fail_write = 1;
    assert(finish_activation(NULL) == 6);
    fixture("iPad1,1", "5.1.1", "Activated"); lose_write = 1;
    assert(finish_activation(NULL) == 6); // successful SetValue without readback is insufficient
    fixture("iPad1,1", "5.1.1", "Unactivated");
    assert(finish_activation(NULL) == 4 && writes == 0);
    fixture("iPad1,1", "5.1.1", "NotReallyActivated");
    assert(finish_activation(NULL) == 4 && writes == 0);
    fixture("iPad1,1", "5.1.1", "FactoryActivated");
    assert(finish_activation(NULL) == 0);
    plist_free(values);
    puts("PASS: automatic activation completion, readback, retry, no clock writes");
}
