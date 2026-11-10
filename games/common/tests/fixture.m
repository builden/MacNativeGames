#import <Cocoa/Cocoa.h>
#include "runtime.h"
#include "fs_host.h"
#include "../users.h"
#ifdef TEST_TOTK
#include "../../totk/runtime/users.h"
#endif
#include <assert.h>
#include <stdlib.h>
#include <string.h>

_Noreturn void runtime_fail(const char *message) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
uint64_t runtime_now_ns(void) { return 10000000000ULL; }
void runtime_autoload_save_file_opened(const char *path) { (void)path; }
void dm_guest_write_prepare(void *addr, size_t n) { (void)addr; (void)n; }
void runtime_fs_log(const char *what, const char *path) { (void)what; (void)path; }
void hle_bind_system_event(void *event, int autoclear) { (void)event; (void)autoclear; }
void hle_signal_system_event(void *event) { (void)event; }
int runtime_romfs_owns(const char *path) { (void)path; return 0; }
int runtime_romfs_handle(uint64_t h) { (void)h; return 0; }
unsigned runtime_romfs_open(uint64_t *out, const char *path, int mode) { (void)out; (void)path; (void)mode; return 1; }
unsigned runtime_romfs_read(uint64_t *out, uint64_t h, int64_t offset, void *buffer, uint64_t size) { (void)out; (void)h; (void)offset; (void)buffer; (void)size; return 1; }
unsigned runtime_romfs_size(int64_t *out, uint64_t h) { (void)out; (void)h; return 1; }
void runtime_romfs_close(uint64_t h) { (void)h; }
unsigned runtime_romfs_entry_type(int *out, const char *path) { (void)out; (void)path; return 1; }

int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 2 && (!strcmp(argv[1], "list") || !strcmp(argv[1], "archived"))) {
        MngUser users[MNG_USERS_ARCHIVED_MAX]; int n = !strcmp(argv[1], "list") ? mng_users_list(users, MNG_USERS_ARCHIVED_MAX) : mng_users_archived(users, MNG_USERS_ARCHIVED_MAX);
        if (n < 0) return 2;
        for (int i = 0; i < n; i++) printf("%s\t%s\n", users[i].id, users[i].name);
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "single")) {
        assert(NSApp == nil); assert(mng_users_select(NULL)); assert(NSApp == nil);
        assert(!strcmp(getenv("MNG_USER_ID"), "default")); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "select")) {
        int result = mng_users_select(NULL);
        printf("selection=%d name=%s\n", result, result ? getenv("MNG_USER_NAME") : "-"); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "probe-select")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500000000), dispatch_get_main_queue(), ^{
            BOOL visible=NO; for(NSWindow *window in NSApp.windows)if(window.visible)visible=YES;
            BOOL ready=NSRunningApplication.currentApplication.finishedLaunching&&visible;
            fprintf(stderr,"chooser: finishedLaunching=%d visible=%d\n",NSRunningApplication.currentApplication.finishedLaunching,visible);
            [NSApp stopModalWithCode:ready ? NSAlertFirstButtonReturn : NSAlertSecondButtonReturn];
        });
        return mng_users_select(NULL) ? 0 : 1;
    }
    if (argc == 2 && !strcmp(argv[1], "probe-manage")) {
        __block BOOL layout = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500000000), dispatch_get_main_queue(), ^{
            NSWindow *window=NSApp.modalWindow;NSButton *buttons[4]={0};
            for(NSView *view in window.contentView.subviews)if([view isKindOfClass:NSButton.class]){
                NSButton *button=(NSButton *)view;
                NSInteger tags[]={NSAlertSecondButtonReturn,NSAlertThirdButtonReturn,NSAlertThirdButtonReturn+1,NSAlertFirstButtonReturn};
                for(int i=0;i<4;i++)if(button.tag==tags[i])buttons[i]=button;
            }
            if(buttons[0]&&buttons[1]&&buttons[2]&&buttons[3]){
                NSRect a=buttons[0].frame,b=buttons[1].frame,c=buttons[2].frame,d=buttons[3].frame;
                layout=window.visible&&a.origin.y==b.origin.y&&c.origin.y==d.origin.y&&a.origin.y>c.origin.y&&a.origin.x==c.origin.x&&b.origin.x==d.origin.x&&a.origin.x<b.origin.x;
            }
            [NSApp stopModalWithCode:NSAlertFirstButtonReturn];
        });
        mng_users_manage(); return layout ? 0 : 1;
    }
    if (argc == 3 && !strcmp(argv[1], "add")) {
        MngUser user; if (mng_users_add(argv[2], &user)) return 2;
        printf("%s\t%s\n", user.id, user.name); return 0;
    }
    if (argc == 3 && (!strcmp(argv[1], "archive") || !strcmp(argv[1], "restore"))) return mng_users_set_archived(argv[2], !strcmp(argv[1], "archive")) ? 2 : 0;
    if (argc != 6) return 3;
    setenv("TOTK_PROFILE_DIR", argv[1], 1); setenv("MNG_USER_ID", argv[2], 1); setenv("MNG_USER_NAME", argv[3], 1);
    uint64_t uid[2]; runtime_account_uid(uid);
#ifdef TEST_TOTK
    if (!strcmp(argv[4], "add-zelda")) {
        extern int runtime_users_add(const char *name);
        assert(runtime_users_add(argv[5]) >= 0); return 0;
    }
    if (!strcmp(argv[4], "archive-current")) {
        assert(mng_users_set_archived(argv[2], 1) == 0);
        RuntimeUser current, list[RUNTIME_USERS_MAX];
        assert(runtime_users_get(list,RUNTIME_USERS_MAX) >= 1 && runtime_users_active(&current) == 0);
        assert(current.lo == uid[0] && current.hi == uid[1] && !strcmp(current.name,argv[3]));
        return 0;
    }
#endif
    uint32_t (*nickname)(char *, const uint64_t *) = runtime_account_override("_ZN2nn7account11GetNicknameEPNS0_8NicknameERKNS0_3UidE");
    char name[33]; assert(nickname && nickname(name, uid) == 0 && !strcmp(name, argv[3]));
    unsigned (*mount)(const char *, const uint64_t *) = runtime_fs_host_override("_ZN2nn2fs13MountSaveDataEPKcRKNS_7account3UidE");
    unsigned (*create)(const char *, int64_t) = runtime_fs_host_override("_ZN2nn2fs10CreateFileEPKcl");
    unsigned (*openFile)(uint64_t *, const char *, int) = runtime_fs_host_override("_ZN2nn2fs8OpenFileEPNS0_10FileHandleEPKci");
    unsigned (*writeFile)(uint64_t, int64_t, const void *, uint64_t, const void *) = runtime_fs_host_override("_ZN2nn2fs9WriteFileENS0_10FileHandleElPKvmRKNS0_11WriteOptionE");
    unsigned (*readFile)(uint64_t *, uint64_t, int64_t, void *, uint64_t) = runtime_fs_host_override("_ZN2nn2fs8ReadFileEPmNS0_10FileHandleElPvm");
    void (*closeFile)(uint64_t) = runtime_fs_host_override("_ZN2nn2fs9CloseFileENS0_10FileHandleE");
    unsigned (*commit)(const char *) = runtime_fs_host_override("_ZN2nn2fs6CommitEPKc");
    assert(mount && create && openFile && writeFile && readFile && closeFile && commit && mount("save", uid) == 0);
    uint64_t other[2] = {uid[0] ^ 1, uid[1]}; assert(mount("other", other) != 0);
    uint64_t handle = 0;
    if (!strcmp(argv[4], "absent")) { assert(openFile(&handle, "save:/marker", 1) != 0); return 0; }
    if (!strcmp(argv[4], "write")) {
        assert(create("save:/marker", (int64_t)strlen(argv[5])) == 0);
        assert(openFile(&handle, "save:/marker", 2) == 0);
        assert(writeFile(handle, 0, argv[5], strlen(argv[5]), NULL) == 0);
        closeFile(handle); assert(commit("save") == 0);
    } else {
        char buffer[64] = {0}; uint64_t count = 0;
        assert(openFile(&handle, "save:/marker", 1) == 0);
        assert(readFile(&count, handle, 0, buffer, sizeof buffer - 1) == 0);
        closeFile(handle); assert(count == strlen(argv[5]) && !strcmp(buffer, argv[5]));
    }
    printf("%016llx%016llx\n", (unsigned long long)uid[1], (unsigned long long)uid[0]);
    return 0;
} }
