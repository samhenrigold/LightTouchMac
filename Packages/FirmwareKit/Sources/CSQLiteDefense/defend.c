#include "CSQLiteDefense.h"

int lt_sqlite_defend(sqlite3 *db) {
    int rc = sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, (int *)0);
    if (rc == SQLITE_OK)
        rc = sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_TRIGGER, 0, (int *)0);
    if (rc == SQLITE_OK)
        rc = sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_VIEW, 0, (int *)0);
#ifdef SQLITE_DBCONFIG_TRUSTED_SCHEMA
    if (rc == SQLITE_OK)
        rc = sqlite3_db_config(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, (int *)0);
#endif
    return rc;
}
