/* Local users shared by native Mac games. Each game retains its own save directories. */
#pragma once

#define MNG_USERS_MAX 8
#define MNG_USERS_ARCHIVED_MAX 64
typedef struct { char id[33]; char name[32]; } MngUser;

/* The store is enabled by mng_users_select at packaged-app startup. */
int mng_users_list(MngUser *out, int max);
int mng_users_add(const char *name, MngUser *out);
int mng_users_archived(MngUser *out, int max);
int mng_users_set_archived(const char *id, int archived);
int mng_users_select(const char *profile);
void mng_users_manage(void);
