/* Shared offline users; per-game legacy identities and saves remain in each game's profile. */
#import <Cocoa/Cocoa.h>
#include "users.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *valid_name(NSString *name) {
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSData *utf8 = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8.length || utf8.length > 31 || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return name;
}
static BOOL valid_id(NSString *uid) {
    if (uid.length != 32) return NO;
    return [uid rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound &&
           ![uid isEqualToString:@"00000000000000000000000000000000"];
}
static NSString *store_root(void) {
    const char *root = getenv("MNG_USERS_DIR");
    return root && *root ? [NSString stringWithUTF8String:root] : nil;
}
static BOOL write_all(int fd, const void *data, size_t size) {
    const uint8_t *p = data;
    while (size) { ssize_t n = write(fd, p, size); if (n < 0 && errno == EINTR) continue; if (n <= 0) return NO; p += n; size -= (size_t)n; }
    return YES;
}
static BOOL write_users(NSString *root, NSArray *users) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:users format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return NO;
    NSString *temporary = [root stringByAppendingPathComponent:[@".users-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *target = [root stringByAppendingPathComponent:@"users.plist"];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    BOOL ok = write_all(fd, data.bytes, data.length) && fsync(fd) == 0;
    if (close(fd)) ok = NO;
    if (ok) ok = rename(temporary.fileSystemRepresentation, target.fileSystemRepresentation) == 0;
    if (!ok) { unlink(temporary.fileSystemRepresentation); return NO; }
    int directory = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY);
    if (directory < 0) return NO;
    ok = fsync(directory) == 0; close(directory); return ok;
}
static BOOL contains_id(NSArray<NSDictionary *> *users, NSString *uid) {
    for (NSDictionary *user in users) if ([user[@"id"] isEqualToString:uid]) return YES;
    return NO;
}
static NSUInteger active_count(NSArray<NSDictionary *> *users) {
    NSUInteger count=0; for (NSDictionary *user in users) if (![user[@"archived"] boolValue]) count++; return count;
}
/* Import Zelda's existing per-game users once by ID. Its first user maps to the shared default. */
static BOOL import_legacy(NSMutableArray *users, NSString *root, BOOL *changed) {
    NSFileManager *fs = NSFileManager.defaultManager;
    NSString *base = root.stringByDeletingLastPathComponent;
    NSArray<NSString *> *folders = [fs contentsOfDirectoryAtPath:base error:nil];
    NSMutableArray<NSString *> *paths=[NSMutableArray array];
    const char *profile=getenv("MNG_USER_PROFILE");
    if(profile&&*profile)[paths addObject:[[NSString stringWithUTF8String:profile] stringByAppendingPathComponent:@"users.txt"]];
    for (NSString *folder in [folders sortedArrayUsingSelector:@selector(compare:)]) {
        [paths addObject:[[base stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"profile/users.txt"]];
    }
    for (NSString *path in paths) {
        NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        BOOL first = YES;
        for (NSString *line in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *entry = [line hasPrefix:@"*"] ? [line substringFromIndex:1] : line;
            NSRange tab = [entry rangeOfString:@"\t"];
            if (tab.location == NSNotFound) continue;
            NSString *uid = [[entry substringToIndex:tab.location] lowercaseString];
            NSString *name = [entry substringFromIndex:tab.location + 1];
            if (!valid_id(uid) || ![valid_name(name) isEqualToString:name]) continue;
            if (first) { first = NO; continue; }
            if (contains_id(users, uid)) continue;
            if (active_count(users) >= MNG_USERS_MAX || users.count >= MNG_USERS_ARCHIVED_MAX) return NO;
            [users addObject:@{@"id":uid, @"name":name}]; *changed = YES;
        }
    }
    return YES;
}
static NSMutableArray *load_users(NSString *root, BOOL *changed) {
    NSString *path = [root stringByAppendingPathComponent:@"users.plist"];
    NSFileManager *fs = NSFileManager.defaultManager;
    NSMutableArray *users;
    if (![fs fileExistsAtPath:path]) {
        users = [NSMutableArray arrayWithObject:@{@"id":@"default", @"name":@"Local"}];
        *changed = YES;
    } else {
        NSData *data = [NSData dataWithContentsOfFile:path];
        id value = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
        if (![value isKindOfClass:NSArray.class] || ![value count] || [value count] > MNG_USERS_ARCHIVED_MAX) return nil;
        users = [NSMutableArray array];
        for (id row in value) {
            if (![row isKindOfClass:NSDictionary.class] || ![row[@"id"] isKindOfClass:NSString.class] || ![row[@"name"] isKindOfClass:NSString.class]) return nil;
            NSString *uid = row[@"id"], *name = row[@"name"];
            id archived=row[@"archived"];
            if ((archived && ![archived isKindOfClass:NSNumber.class]) || (!users.count ? ![uid isEqualToString:@"default"] || [archived boolValue] : !valid_id(uid)) || ![valid_name(name) isEqualToString:name] || contains_id(users, uid)) return nil;
            [users addObject:@{@"id":uid, @"name":name, @"archived":@([archived boolValue])}];
        }
        if (active_count(users) > MNG_USERS_MAX) return nil;
    }
    if (!import_legacy(users, root, changed)) return nil;
    return users;
}
static int store_lock(NSString *root) {
    if (!root || ![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) return -1;
    int fd = open([[root stringByAppendingPathComponent:@".lock"] fileSystemRepresentation], O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX)) { close(fd); return -1; }
    return fd;
}

static int list_users(MngUser *out, int max, BOOL archived) {
    @autoreleasepool {
        if (!out || max < 1) return -1;
        NSString *root = store_root(); int lock = store_lock(root); if (lock < 0) return -1;
        BOOL changed = NO; NSArray *users = load_users(root, &changed);
        if (!users || (changed && !write_users(root, users))) { close(lock); return -1; }
        int count = 0;
        for (NSDictionary *user in users) {
            if ([user[@"archived"] boolValue] != archived || count == max) continue;
            snprintf(out[count].id, sizeof out[count].id, "%s", [user[@"id"] UTF8String]);
            snprintf(out[count].name, sizeof out[count].name, "%s", [user[@"name"] UTF8String]); count++;
        }
        close(lock); return count;
    }
}
int mng_users_list(MngUser *out, int max) { return list_users(out,max,NO); }
int mng_users_archived(MngUser *out, int max) { return list_users(out,max,YES); }
int mng_users_add(const char *input, MngUser *out) {
    @autoreleasepool {
        NSString *name = input ? valid_name([NSString stringWithUTF8String:input]) : nil;
        if (!name || !out) return -1;
        NSString *root = store_root(); int lock = store_lock(root); if (lock < 0) return -1;
        BOOL changed = NO; NSMutableArray *users = load_users(root, &changed);
        if (!users || active_count(users) >= MNG_USERS_MAX || users.count >= MNG_USERS_ARCHIVED_MAX) { close(lock); return -1; }
        for (NSDictionary *user in users) if ([name caseInsensitiveCompare:user[@"name"]] == NSOrderedSame) { close(lock); return -1; }
        uint64_t uid[2]; NSString *hex;
        do { arc4random_buf(uid, sizeof uid); hex = [NSString stringWithFormat:@"%016llx%016llx", (unsigned long long)uid[1], (unsigned long long)uid[0]]; } while (!valid_id(hex) || contains_id(users, hex));
        [users addObject:@{@"id":hex, @"name":name}];
        if (!write_users(root, users)) { close(lock); return -1; }
        snprintf(out->id, sizeof out->id, "%s", hex.UTF8String); snprintf(out->name, sizeof out->name, "%s", name.UTF8String);
        close(lock); return 0;
    }
}
int mng_users_set_archived(const char *input, int archived) {
    @autoreleasepool {
        NSString *uid=input?[NSString stringWithUTF8String:input]:nil;
        if (!valid_id(uid)) return -1; /* The default user and its existing saves stay available. */
        NSString *root=store_root();int lock=store_lock(root);if(lock<0)return -1;
        BOOL changed=NO;NSMutableArray *users=load_users(root,&changed);if(!users){close(lock);return -1;}
        NSUInteger index=[users indexOfObjectPassingTest:^BOOL(NSDictionary *row,NSUInteger i,BOOL *stop){(void)i;(void)stop;return [row[@"id"] isEqualToString:uid];}];
        if(index==NSNotFound || (!archived && [users[index][@"archived"] boolValue] && active_count(users)>=MNG_USERS_MAX)){close(lock);return -1;}
        NSDictionary *row=users[index];users[index]=@{@"id":uid,@"name":row[@"name"],@"archived":@((BOOL)!!archived)};
        BOOL ok=write_users(root,users);close(lock);return ok?0:-1;
    }
}
static BOOL chinese(void) { const char *language = getenv("TOTK_LANG"); return language && !strncmp(language, "zh", 2); }
static NSModalResponse show_alert(NSAlert *alert) { [alert.window center]; [alert.window makeKeyAndOrderFront:nil]; return [alert runModal]; }
static void user_error(NSString *message) { NSAlert *alert = [NSAlert new]; alert.messageText = message; show_alert(alert); }
static void prepare_app(void) {
    static BOOL finished;
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    if (!NSApp.running && !finished) { [NSApp finishLaunching]; finished=YES; }
    [NSApp activateIgnoringOtherApps:YES];
}
static NSInteger last_user(const char *profile, MngUser *users, int count) {
    if (!profile) return 0;
    NSString *path = [[NSString stringWithUTF8String:profile] stringByAppendingPathComponent:@"users.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *first = nil, *marked = nil;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        BOOL star = [line hasPrefix:@"*"]; NSString *row = star ? [line substringFromIndex:1] : line;
        NSRange tab = [row rangeOfString:@"\t"]; if (tab.location == NSNotFound) continue;
        NSString *uid = [[row substringToIndex:tab.location] lowercaseString]; if (!valid_id(uid)) continue;
        if (!first) first = uid; if (star) marked = uid;
    }
    if (!marked || [marked isEqualToString:first]) return 0;
    for (int i = 1; i < count; i++) if ([marked isEqualToString:@(users[i].id)]) return i;
    return 0;
}
int mng_users_select(const char *profile) {
    @autoreleasepool {
        if(profile&&*profile&&setenv("MNG_USER_PROFILE",profile,1))return 0;
        if (!store_root()) {
            const char *home = getenv("HOME"); if (!home || !*home) return 0;
            NSString *root = [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames/Accounts"];
            if (setenv("MNG_USERS_DIR", root.fileSystemRepresentation, 1)) return 0;
        }
        MngUser users[MNG_USERS_MAX]; int count = mng_users_list(users, MNG_USERS_MAX);
        if (count < 1) { prepare_app(); user_error(chinese()?@"无法读取用户列表；现有存档未更改。":@"Cannot read the user list; existing saves were not changed."); return 0; }
        NSInteger selected = last_user(profile, users, count);
        if (count > 1) {
            prepare_app(); NSAlert *alert = [NSAlert new];
            alert.messageText = chinese()?@"选择用户":@"Select a user";
            alert.informativeText = chinese()?@"请选择本次运行的用户。":@"Choose the user for this session.";
            NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,300,26) pullsDown:NO];
            popup.accessibilityLabel = chinese()?@"用户":@"User";
            for (int i=0;i<count;i++) [popup addItemWithTitle:@(users[i].name)];
            [popup selectItemAtIndex:selected]; alert.accessoryView=popup;
            [alert addButtonWithTitle:chinese()?@"开始游戏":@"Start Game"];
            [alert addButtonWithTitle:chinese()?@"退出":@"Quit"];
            NSModalResponse response=show_alert(alert);
            if (response != NSAlertFirstButtonReturn) return 0;
            selected=popup.indexOfSelectedItem;
        }
        return setenv("MNG_USER_ID",users[selected].id,1)==0 && setenv("MNG_USER_NAME",users[selected].name,1)==0;
    }
}
@interface MNGUserPanelActions : NSObject <NSWindowDelegate>
@end
@implementation MNGUserPanelActions
- (void)choose:(NSButton *)button { [NSApp stopModalWithCode:button.tag]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender;[NSApp stopModalWithCode:NSAlertFirstButtonReturn];return NO; }
@end

static NSModalResponse users_panel(MngUser *users, int count, NSInteger *selected) {
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,440,248)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    panel.title=chinese()?@"用户管理":@"Manage users";
    MNGUserPanelActions *actions=[MNGUserPanelActions new];panel.delegate=actions;
    NSTextField *description=[NSTextField wrappingLabelWithString:chinese()?@"用户在支持此功能的游戏间共用；存档按游戏和用户分别保存。":@"Users are shared by supported games; saves remain separate for each game and user."];
    description.frame=NSMakeRect(20,190,400,38);[panel.contentView addSubview:description];
    NSPopUpButton *popup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20,150,400,28) pullsDown:NO];
    popup.accessibilityLabel=chinese()?@"用户列表":@"Users";for(int i=0;i<count;i++)[popup addItemWithTitle:@(users[i].name)];[panel.contentView addSubview:popup];
    NSArray *titles=chinese()?@[@"添加用户…",@"移除用户…",@"恢复用户…",@"关闭"]:@[@"Add User…",@"Remove User…",@"Restore User…",@"Close"];
    NSInteger tags[]={NSAlertSecondButtonReturn,NSAlertThirdButtonReturn,NSAlertThirdButtonReturn+1,NSAlertFirstButtonReturn};
    for(int i=0;i<4;i++){
        NSButton *button=[NSButton buttonWithTitle:titles[i] target:actions action:@selector(choose:)];button.tag=tags[i];
        if(i==3)button.keyEquivalent=@"\033";
        button.frame=NSMakeRect(20+(i%2)*205,94-(i/2)*42,195,32);[panel.contentView addSubview:button];
    }
    [panel center];[panel makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response=[NSApp runModalForWindow:panel];*selected=popup.indexOfSelectedItem;[panel orderOut:nil];return response;
}
void mng_users_manage(void) {
    @autoreleasepool {
        prepare_app();
        for (;;) {
            MngUser users[MNG_USERS_MAX]; int count=mng_users_list(users,MNG_USERS_MAX);
            if (count<1) { user_error(chinese()?@"无法读取用户列表。":@"Cannot read the user list."); return; }
            NSInteger selected=0;NSModalResponse response=users_panel(users,count,&selected);
            if(response==NSAlertFirstButtonReturn)return;
            if(response==NSAlertThirdButtonReturn){
                if(selected<=0){user_error(chinese()?@"默认用户不能移除。":@"The default user cannot be removed.");continue;}
                NSAlert *confirm=[NSAlert new];confirm.messageText=chinese()?@"移除此用户？":@"Remove this user?";
                confirm.informativeText=chinese()?@"各游戏的存档会保留，可以在这里恢复该用户。":@"Game saves are kept. You can restore this user here.";
                [confirm addButtonWithTitle:chinese()?@"移除":@"Remove"];[confirm addButtonWithTitle:chinese()?@"取消":@"Cancel"];
                if(show_alert(confirm)==NSAlertFirstButtonReturn&&mng_users_set_archived(users[selected].id,1))user_error(chinese()?@"无法移除用户。":@"Cannot remove user.");
                continue;
            }
            if(response==NSAlertThirdButtonReturn+1){
                MngUser removed[MNG_USERS_ARCHIVED_MAX];int n=mng_users_archived(removed,MNG_USERS_ARCHIVED_MAX);
                if(n<=0){user_error(chinese()?@"没有可恢复的用户。":@"No removed users to restore.");continue;}
                NSAlert *restore=[NSAlert new];restore.messageText=chinese()?@"恢复用户":@"Restore a user";
                NSPopUpButton *choices=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,300,26) pullsDown:NO];
                choices.accessibilityLabel=chinese()?@"已移除的用户":@"Removed users";for(int i=0;i<n;i++)[choices addItemWithTitle:@(removed[i].name)];restore.accessoryView=choices;
                [restore addButtonWithTitle:chinese()?@"恢复":@"Restore"];[restore addButtonWithTitle:chinese()?@"取消":@"Cancel"];
                if(show_alert(restore)==NSAlertFirstButtonReturn&&mng_users_set_archived(removed[choices.indexOfSelectedItem].id,0))user_error(chinese()?@"无法恢复用户，最多允许 8 个用户。":@"Cannot restore user; at most 8 users are allowed.");
                continue;
            }
            if(response!=NSAlertSecondButtonReturn)return;
            NSAlert *add=[NSAlert new]; add.messageText=chinese()?@"添加用户":@"Add a user";
            add.informativeText=chinese()?@"输入用户名称（最多 31 个 UTF-8 字节）。":@"Enter a user name (up to 31 UTF-8 bytes).";
            NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,300,26)]; field.accessibilityLabel=chinese()?@"用户名称":@"User name"; add.accessoryView=field;
            [add addButtonWithTitle:chinese()?@"添加":@"Add"]; [add addButtonWithTitle:chinese()?@"取消":@"Cancel"]; [add.window setInitialFirstResponder:field];
            if (show_alert(add)!=NSAlertFirstButtonReturn) continue;
            MngUser added; if (mng_users_add(field.stringValue.UTF8String,&added)) user_error(chinese()?@"无法添加用户：名称无效、已存在，或已达 8 人上限。":@"Cannot add user: invalid or duplicate name, or the 8-user limit was reached.");
        }
    }
}
