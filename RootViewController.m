#import "RootViewController.h"

#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

/* ---------------- 命令行调用 ---------------- */

static BOOL IsDirAtForDiag(NSString *p) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    return [fm fileExistsAtPath:p isDirectory:&isDir] && isDir;
}

static NSString *DebpackPath(void) {
    NSArray<NSString *> *cands = @[
        @"/var/jb/usr/bin/debpack",
        @"/usr/bin/debpack",
        @"/usr/local/bin/debpack",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

static NSString *RunCapture(NSString *tool, NSArray<NSString *> *args, int *spawnRc) {
    if (spawnRc) *spawnRc = -1;
    int pfd[2];
    if (pipe(pfd) != 0) return @"";

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 2);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);

    const char *argv[32];
    int i = 0;
    argv[i++] = [tool fileSystemRepresentation];
    for (NSString *a in args) {
        if (i >= 31) break;
        argv[i++] = [a fileSystemRepresentation];
    }
    argv[i] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [tool fileSystemRepresentation], &fa, NULL,
                         (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pfd[1]);
    if (rc != 0) {
        close(pfd[0]);
        return @"";
    }

    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    ssize_t n = 0;
    while ((n = read(pfd[0], tmp, sizeof(tmp))) > 0) {
        [buf appendBytes:tmp length:(NSUInteger)n];
    }
    close(pfd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    if (spawnRc) *spawnRc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    return s ?: @"";
}

static int RunStreaming(NSString *tool, NSArray<NSString *> *args, void (^line)(NSString *)) {
    int pfd[2];
    if (pipe(pfd) != 0) return -1;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 2);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);

    const char *argv[32];
    int i = 0;
    argv[i++] = [tool fileSystemRepresentation];
    for (NSString *a in args) {
        if (i >= 31) break;
        argv[i++] = [a fileSystemRepresentation];
    }
    argv[i] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [tool fileSystemRepresentation], &fa, NULL,
                         (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pfd[1]);
    if (rc != 0) {
        close(pfd[0]);
        return rc;
    }

    FILE *fp = fdopen(pfd[0], "r");
    if (fp) {
        char buf[8192];
        while (fgets(buf, sizeof(buf), fp)) {
            NSString *s = [NSString stringWithUTF8String:buf];
            if (!s) continue;
            s = [s stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            if (s.length > 0 && line) line(s);
        }
        fclose(fp);
    } else {
        close(pfd[0]);
    }

    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* ---------------- 日志界面 ---------------- */

@interface LogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
- (void)appendLine:(NSString *)s;
@end

@implementation LogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.title == nil) self.title = @"正在导出";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.textView.text = @"";
    [self.view addSubview:self.textView];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(done:)];
    [self.spinner startAnimating];
}

- (void)done:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)appendLine:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = [self.textView.text stringByAppendingFormat:@"%@\n", s];
        if (self.textView.text.length > 0) {
            NSRange r = NSMakeRange(self.textView.text.length - 1, 1);
            [self.textView scrollRangeToVisible:r];
        }
    });
}

- (void)setText:(NSString *)t {
    self.textView.text = t ?: @"";
}

@end

/* ---------------- 主列表 ---------------- */

@interface RootViewController () <UISearchBarDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *allItems;
@property (nonatomic, strong) NSArray<NSDictionary *> *shownItems;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIDs;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIBarButtonItem *exportItem;
@property (nonatomic, strong) UIBarButtonItem *riskyItem;
@property (nonatomic, assign) BOOL includeRisky;
@property (nonatomic, assign) BOOL busy;
@end

@implementation RootViewController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        _allItems = @[];
        _shownItems = @[];
        _selectedIDs = [NSMutableSet set];
        _includeRisky = NO;
        _busy = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DebPack";

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    self.searchBar.placeholder = @"搜名字或标识";
    self.searchBar.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(selectAll:)];

    UIBarButtonItem *sp1 = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *invert = [[UIBarButtonItem alloc] initWithTitle:@"反选"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(invertSelection:)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(clearSelection:)];
    self.riskyItem = [[UIBarButtonItem alloc] initWithTitle:@"系统包:关"
                                                      style:UIBarButtonItemStylePlain
                                                     target:self
                                                     action:@selector(toggleRisky:)];
    self.exportItem = [[UIBarButtonItem alloc] initWithTitle:@"导出 (0)"
                                                       style:UIBarButtonItemStyleDone
                                                      target:self
                                                      action:@selector(startExport:)];
    self.toolbarItems = @[invert, clear, sp1, self.riskyItem, self.exportItem];

    [self loadPackages];
}

- (void)loadPackages {
    NSString *tool = DebpackPath();
    if (!tool) {
        [self showAlert:@"找不到 debpack 命令行工具，请先安装 com.debpack.cli"];
        return;
    }
    self.title = @"读取中…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int spawnRc = -1;
        NSString *out = RunCapture(tool, @[@"list", @"--json"], &spawnRc);
        NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *arr = nil;
        if (d) arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) {
                [self showDiagnostics:tool spawnRc:spawnRc output:out];
                return;
            }
            self.allItems = arr;
            [self applyFilter:@""];
        });
    });
}

- (void)showDiagnostics:(NSString *)tool spawnRc:(int)spawnRc output:(NSString *)out {
    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"euid = %d %@\n", geteuid(),
          geteuid() == 0 ? @"(root，正常)" : @"(不是 root！setuid 没生效)"];
    [msg appendFormat:@"工具路径: %@\n", tool ?: @"(未找到)"];
    [msg appendFormat:@"/var/jb 存在: %@\n", IsDirAtForDiag(@"/var/jb") ? @"是" : @"否"];
    [msg appendFormat:@"spawn 退出码: %d\n", spawnRc];
    [msg appendFormat:@"输出长度: %lu\n", (unsigned long)out.length];
    [msg appendString:@"\n===== 命令输出 =====\n"];
    if (out.length == 0) {
        [msg appendString:@"(空)"];
    } else {
        NSString *head = out.length > 600 ? [out substringToIndex:600] : out;
        [msg appendString:head];
    }

    LogViewController *log = [[LogViewController alloc] init];
    log.title = @"诊断信息";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:log];
    [self presentViewController:nav animated:YES completion:^{
        [log setText:msg];
    }];
}

- (void)applyFilter:(NSString *)query {
    NSString *q = [[query ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (q.length == 0) {
        self.shownItems = self.allItems;
    } else {
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        for (NSDictionary *d in self.allItems) {
            NSString *name = [(d[@"name"] ?: @"") lowercaseString];
            NSString *ident = [(d[@"id"] ?: @"") lowercaseString];
            if ([name containsString:q] || [ident containsString:q]) [out addObject:d];
        }
        self.shownItems = out;
    }
    [self.tableView reloadData];
    [self updateStatus];
}

- (void)updateStatus {
    NSUInteger n = self.selectedIDs.count;
    self.title = [NSString stringWithFormat:@"DebPack (%lu/%lu)",
                  (unsigned long)n, (unsigned long)self.allItems.count];
    self.exportItem.title = [NSString stringWithFormat:@"导出 (%lu)", (unsigned long)n];
    self.exportItem.enabled = (n > 0 && !self.busy);
}

- (void)selectAll:(id)sender {
    for (NSDictionary *d in self.shownItems) {
        NSString *ident = d[@"id"];
        if (ident.length > 0) [self.selectedIDs addObject:ident];
    }
    [self.tableView reloadData];
    [self updateStatus];
}

- (void)invertSelection:(id)sender {
    for (NSDictionary *d in self.shownItems) {
        NSString *ident = d[@"id"];
        if (ident.length == 0) continue;
        if ([self.selectedIDs containsObject:ident]) [self.selectedIDs removeObject:ident];
        else [self.selectedIDs addObject:ident];
    }
    [self.tableView reloadData];
    [self updateStatus];
}

- (void)clearSelection:(id)sender {
    [self.selectedIDs removeAllObjects];
    [self.tableView reloadData];
    [self updateStatus];
}

- (void)toggleRisky:(id)sender {
    self.includeRisky = !self.includeRisky;
    self.riskyItem.title = self.includeRisky ? @"系统包:开" : @"系统包:关";
}

- (void)startExport:(id)sender {
    if (self.busy) return;
    NSString *tool = DebpackPath();
    if (!tool) {
        [self showAlert:@"找不到 debpack 命令行工具"];
        return;
    }
    if (self.selectedIDs.count == 0) return;

    NSString *idsFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"debpack_ids.txt"];
    NSString *body = [[self.selectedIDs allObjects] componentsJoinedByString:@"\n"];
    [body writeToFile:idsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"export", @"--ids-file", idsFile, nil];
    if (self.includeRisky) [args addObject:@"--force"];

    LogViewController *log = [[LogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:log];
    [self presentViewController:nav animated:YES completion:nil];

    self.busy = YES;
    [self updateStatus];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int rc = RunStreaming(tool, args, ^(NSString *s) {
            [log appendLine:s];
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            [log appendLine:(rc == 0) ? @"\n===== 全部完成 ====="
                                      : [NSString stringWithFormat:@"\n退出码 %d，请往上翻看失败原因", rc]];
            [self updateStatus];
        });
    });
}

- (void)showAlert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"DebPack"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyFilter:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.shownItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"cell"];
    }
    NSDictionary *d = self.shownItems[(NSUInteger)indexPath.row];
    NSString *ident = d[@"id"] ?: @"";
    NSString *name = d[@"name"] ?: ident;
    NSString *ver = d[@"version"] ?: @"";

    NSMutableString *sub = [NSMutableString string];
    [sub appendString:ident];
    if (ver.length > 0) [sub appendFormat:@"  %@", ver];
    if ([d[@"hasPrefs"] boolValue]) [sub appendString:@"  ·有配置"];
    if ([d[@"risky"] boolValue]) [sub appendString:@"  ·系统底层"];

    cell.textLabel.text = name;
    cell.detailTextLabel.text = sub;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = [self.selectedIDs containsObject:ident]
                             ? UITableViewCellAccessoryCheckmark
                             : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.shownItems[(NSUInteger)indexPath.row];
    NSString *ident = d[@"id"];
    if (ident.length == 0) return;
    if ([self.selectedIDs containsObject:ident]) [self.selectedIDs removeObject:ident];
    else [self.selectedIDs addObject:ident];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateStatus];
}

@end
