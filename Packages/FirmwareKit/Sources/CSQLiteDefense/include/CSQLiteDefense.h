// sqlite3_db_config, which is variadic and so not callable from Swift, for a database a guest wrote.
#ifndef LT_CSQLITEDEFENSE_H
#define LT_CSQLITEDEFENSE_H
#include <sqlite3.h>
// Before anything is prepared on `db`: defensive mode (no writable_schema, no shadow-table writes), triggers and
// views off, and the schema untrusted (no function with side effects from it). SQLITE_OK, or the first failure.
int lt_sqlite_defend(sqlite3 *db);
#endif
