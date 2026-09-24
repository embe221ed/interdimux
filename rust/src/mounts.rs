//! Which paths live on a filesystem whose stat() can block indefinitely.
//!
//! Every row the picker draws can cost filesystem probes before the first
//! paint: the git badge walks `<dir>/.git` up to `/`, a directory row's type
//! badge is up to 11 marker probes, and a recent/zoxide directory is checked
//! for existence.  On a stalled NFS/CIFS/sshfs mount -- or an automount point
//! that has to (re)mount -- each of those blocks for the mount's timeout, and
//! bash captures the binary's whole output, so NOTHING paints until every one
//! returns.  Measured with a FUSE filesystem whose lookups stall for 1 s: one
//! such directory in the recent list made `--list` take 11 s instead of 0.1 s.
//!
//! So such paths are not probed at all: no git badge, no type badge, and a
//! recent/zoxide entry is offered without an existence check (connect_dir
//! reports it if it is gone).  A helper thread with a deadline would not bound
//! it: a thread stuck in a non-killable stat keeps the stdout pipe open until
//! it returns, and bash waits for EOF.
//!
//! Classified once per run from /proc/self/mountinfo (INTERDIMUX_MOUNTINFO
//! overrides the path, for tests); where there is no such file (macOS, BSD)
//! nothing is classified and every path is probed as before.  bash's
//! is_remote_path applies the same table.  (bash also hands its table to fzf's
//! callbacks in INTERDIMUX_MOUNTS; this binary reads mountinfo itself, since
//! the navigator only exports that when the bash renderer draws the list.)

use std::collections::HashMap;
use std::sync::OnceLock;

/// Filesystem types that are network or user-space (FUSE) filesystems, or an
/// automount trigger: a stat on them can wait on something other than a disk.
/// `superopts` is the line's last field, the superblock options.
fn blocking_fs(fstype: &str, superopts: &str) -> bool {
    match fstype {
        "nfs" | "nfs4" | "cifs" | "smb3" | "smbfs" | "ncpfs" | "afs" | "ceph" | "coda"
        | "lustre" | "gpfs" | "orangefs" | "beegfs" | "autofs" | "fuse" => true,
        // 9p is classified by its transport.  Over tcp or rdma it is a network
        // share.  Over fd it is WSL2's drvfs (/mnt/c, the Windows drives), and
        // over virtio, unix or xen it is a VM's share of its host's own disk
        // (QEMU virtfs, Lima): slow per stat, never the hung-server case, so
        // those keep their badges.
        "9p" => superopts.split(',').any(|o| o == "trans=tcp" || o == "trans=rdma"),
        // FUSE filesystems known to be backed by local storage (encrypted or
        // union views of a local directory) keep their badges.  `fuseblk` --
        // ntfs-3g, exfat -- is a local block device and never matched "fuse.".
        "fuse.gocryptfs" | "fuse.encfs" | "fuse.cryfs" | "fuse.securefs" | "fuse.bindfs"
        | "fuse.mergerfs" | "fuse.unionfs" | "fuse.unionfs-fuse" | "fuse.fuse-overlayfs" => false,
        t => t.starts_with("fuse."),
    }
}

/// mountinfo escapes space, tab, newline and backslash in paths as \ooo.
fn unescape(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 3 < b.len() && b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c)) {
            let v = |k: usize| u32::from(b[i + k] - b'0');
            out.push(((v(1) * 64 + v(2) * 8 + v(3)) & 0xff) as u8);
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Is `point` the mount point of `path`, or an ancestor of it?
fn covers(point: &str, path: &str) -> bool {
    point == "/"
        || path == point
        || (path.len() > point.len() && path.starts_with(point) && path.as_bytes()[point.len()] == b'/')
}

pub struct Table {
    /// mount point -> "a stat there can block"; the LAST mount at a point wins,
    /// as it does in the kernel (an automount point shadowed by what it
    /// mounted is the mounted filesystem).
    points: Vec<(String, bool)>,
}

impl Table {
    /// The table `text` (mountinfo) describes, with `/` and each of `exempt`
    /// never skipped (see [`Table::exempt`]).
    pub fn parse(text: &str, exempt: &[&str]) -> Table {
        let mut map: HashMap<String, bool> = HashMap::new();
        for line in text.lines() {
            // "<id> <parent> <maj:min> <root> <point> <opts> [optional...] - <fstype> <src> <superopts>"
            let Some((left, right)) = line.split_once(" - ") else { continue };
            let Some(point) = left.split(' ').nth(4) else { continue };
            let mut rf = right.split(' ');
            let fstype = rf.next().unwrap_or("");
            let blocks = blocking_fs(fstype, rf.nth(1).unwrap_or(""));
            // A local mount only matters once it can shadow, or sit inside, a
            // blocking one -- which, in mount order, is after the first of
            // those.  (It also makes a blocking mount laid OVER an older local
            // submount win for paths below it, as it does in the kernel.)
            if !blocks && map.is_empty() {
                continue;
            }
            map.insert(unescape(point), blocks);
        }
        let mut t = Table { points: map.into_iter().collect() };
        t.exempt("/");
        for p in exempt {
            t.exempt(p);
        }
        t
    }

    /// Never skip the filesystem `path` is on.  For what the picker cannot
    /// avoid touching anyway: `/` (the binary, bash, /proc) and the filesystem
    /// $HOME is on (the recent list itself lives there).  If either stalls,
    /// nothing here can paint regardless -- and an NFS home, the common case,
    /// keeps its badges.
    pub fn exempt(&mut self, path: &str) {
        if path.is_empty() {
            return;
        }
        if let Some(i) = self.covering(path) {
            self.points[i].1 = false;
        }
    }

    fn any_blocking(&self) -> bool {
        self.points.iter().any(|(_, r)| *r)
    }

    /// Index of the mount a path is on: the longest covering mount point.
    fn covering(&self, path: &str) -> Option<usize> {
        let mut best: Option<usize> = None;
        for (i, (pt, _)) in self.points.iter().enumerate() {
            if covers(pt, path) && best.map_or(true, |b| pt.len() > self.points[b].0.len()) {
                best = Some(i);
            }
        }
        best
    }

    pub fn is_blocking(&self, path: &str) -> bool {
        if !path.starts_with('/') || !self.any_blocking() {
            return false;
        }
        self.covering(path).map_or(false, |i| self.points[i].1)
    }
}

static TABLE: OnceLock<Table> = OnceLock::new();

/// Should `path` be left unprobed?  Read and parsed on first use only.
pub fn is_remote(path: &str) -> bool {
    TABLE
        .get_or_init(|| {
            let src = std::env::var("INTERDIMUX_MOUNTINFO")
                .ok()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "/proc/self/mountinfo".to_string());
            let home = std::env::var("HOME").unwrap_or_default();
            match std::fs::read(&src) {
                Ok(b) => {
                    let mut t = Table::parse(&String::from_utf8_lossy(&b), &[&home]);
                    // Only stat'ed while something still blocks.
                    if t.any_blocking() {
                        if let Some(r) = resolved_home(&home) {
                            t.exempt(&r);
                        }
                    }
                    t
                }
                Err(_) => Table { points: Vec::new() },
            }
        })
        .is_blocking(path)
}

/// $HOME with its symlinks resolved, when the literal path goes through one;
/// None otherwise.  tmux reports a pane's cwd resolved, so a HOME that is a
/// symlink onto a network mount (/home/u -> /gpfs/home/u, as on some clusters)
/// is used through the mount's own path, and exempting only the literal one
/// left every pane there badge-less.  The same test as bash's _mounts_read:
/// each ancestor of the literal string lstat'ed in turn, and only then resolved.
fn resolved_home(home: &str) -> Option<String> {
    if !home.starts_with('/') {
        return None;
    }
    let mut p = home;
    while !p.is_empty() && p != "/" {
        if std::fs::symlink_metadata(p).map_or(false, |m| m.file_type().is_symlink()) {
            return std::fs::canonicalize(home).ok()?.to_str().map(str::to_string);
        }
        match p.rfind('/') {
            Some(i) => p = &p[..i],
            None => break,
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const INFO: &str = "\
29 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
36 25 0:31 / /proc/sys/fs/binfmt_misc rw,relatime shared:13 - autofs systemd-1 rw
49 36 0:35 / /proc/sys/fs/binfmt_misc rw,nosuid shared:48 - binfmt_misc binfmt_misc rw
60 29 0:50 / /mnt/nas rw,relatime shared:60 - nfs4 srv:/export rw
61 60 0:51 / /mnt/nas/scratch rw shared:61 - tmpfs tmpfs rw
62 29 0:52 / /mnt/ssh\\040box rw,nosuid,nodev shared:62 - fuse.sshfs me@box: rw
63 29 0:53 / /home/u/vault rw,nosuid,nodev shared:63 - fuse.gocryptfs /home/u/.vault rw
64 29 0:54 / /media/win rw shared:64 - fuseblk /dev/sdb1 rw
65 29 0:55 / /net rw shared:65 - autofs /etc/auto.net rw
";

    #[test]
    fn network_and_fuse_mounts_are_blocking_local_ones_are_not() {
        let t = Table::parse(INFO, &["/home/u"]);
        assert!(t.is_blocking("/mnt/nas"));
        assert!(t.is_blocking("/mnt/nas/proj/src"));
        assert!(t.is_blocking("/mnt/ssh box/code"), "mountinfo's \\040 escape");
        assert!(t.is_blocking("/net/server/share"), "an automount trigger");
        assert!(!t.is_blocking("/mnt/nasty"), "a prefix that is not a path component");
        assert!(!t.is_blocking("/home/u/code"));
        assert!(!t.is_blocking("/home/u/vault/proj"), "a local-backed FUSE fs");
        assert!(!t.is_blocking("/media/win/proj"), "fuseblk is a local disk");
        assert!(!t.is_blocking("/mnt/nas/scratch/x"), "a local mount inside a remote one");
        assert!(!t.is_blocking("/proc/sys/fs/binfmt_misc"), "the last mount at a point wins");
        assert!(!t.is_blocking("relative/path"));
    }

    #[test]
    fn the_filesystems_the_picker_touches_anyway_are_never_skipped() {
        let nfs_everything = "\
1 0 0:1 / / rw - nfs4 srv:/root rw
2 1 0:2 / /home rw - nfs4 srv:/home rw
3 1 0:3 / /mnt/nas rw - nfs4 srv:/nas rw
";
        let t = Table::parse(nfs_everything, &["/home/u"]);
        assert!(!t.is_blocking("/usr/share"), "an NFS root is where everything runs from");
        assert!(!t.is_blocking("/home/u/code/proj"), "an NFS home keeps its badges");
        assert!(t.is_blocking("/mnt/nas/proj"), "another NFS mount is still skipped");
    }

    #[test]
    fn a_blocking_mount_laid_over_an_older_submount_hides_it() {
        let info = "\
1 0 8:1 / / rw - ext4 /dev/sda1 rw
2 1 0:2 / /mnt/x/y rw - tmpfs tmpfs rw
3 1 0:3 / /mnt/x rw - nfs4 srv:/x rw
";
        assert!(Table::parse(info, &["/home/u"]).is_blocking("/mnt/x/y/z"));
    }

    #[test]
    fn nine_p_blocks_only_over_a_network_transport() {
        // WSL2's Windows drives, a QEMU/Lima share, and the same over tcp/rdma
        let info = "\
1 0 8:1 / / rw - ext4 /dev/sda1 rw
95 70 0:61 / /mnt/c rw,noatime - 9p drvfs rw,dirsync,aname=drvfs;path=C:\\;uid=1000;gid=1000;symlinkroot=/mnt/,mmap,access=client,msize=65536,trans=fd,rfd=5,wfd=5
96 70 0:62 / /mnt/share rw,relatime - 9p hostshare rw,access=client,msize=512000,trans=virtio
97 70 0:63 / /mnt/net9p rw,relatime - 9p 10.0.0.1 rw,access=user,trans=tcp,port=564
98 70 0:64 / /mnt/ib9p rw,relatime - 9p 10.0.0.2 rw,trans=rdma,port=5640
";
        let t = Table::parse(info, &["/home/u"]);
        assert!(!t.is_blocking("/mnt/c/Users/me/proj"), "WSL2 drvfs (trans=fd) is the local disk");
        assert!(!t.is_blocking("/mnt/share/proj"), "a virtio share is the host's disk");
        assert!(t.is_blocking("/mnt/net9p/proj"), "9p over tcp is a network share");
        assert!(t.is_blocking("/mnt/ib9p/proj"), "9p over rdma is a network share");
    }

    #[test]
    fn a_home_that_is_a_symlink_onto_a_network_mount_keeps_its_badges() {
        // tmux reports a pane's cwd resolved: /…/gpfs/u/proj, not /…/linkhome/proj
        let root = std::env::temp_dir().join(format!("imux-mounts-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("gpfs/u/proj")).unwrap();
        std::fs::create_dir_all(root.join("gpfs/other")).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        let r = root.to_str().unwrap();
        std::os::unix::fs::symlink(root.join("gpfs/u"), root.join("linkhome")).unwrap();
        let home = format!("{r}/linkhome");
        let info = format!("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n900 1 0:900 / {r}/gpfs rw - nfs4 srv:/gpfs rw\n");
        let mut t = Table::parse(&info, &[&home]);
        assert!(t.is_blocking(&format!("{r}/gpfs/u/proj")), "the literal HOME alone does not reach it");
        assert_eq!(resolved_home(&home).as_deref(), Some(format!("{r}/gpfs/u").as_str()));
        t.exempt(&resolved_home(&home).unwrap());
        assert!(!t.is_blocking(&format!("{r}/gpfs/u/proj")), "the mount HOME resolves onto is exempt");
        // a HOME with no symlink on its way is not resolved (nothing to stat for)
        assert_eq!(resolved_home(&format!("{r}/gpfs/u")), None);
        assert_eq!(resolved_home("relative/home"), None);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn an_escape_is_exactly_three_octal_digits() {
        // a digit after the escape is part of the name: `nas 1`, not `nas` + 0x01
        // (bash's printf %b read \0 plus three MORE digits; see _mount_unescape)
        assert_eq!(unescape("/mnt/nas\\0401"), "/mnt/nas 1");
        assert_eq!(unescape("/mnt/tab\\0115"), "/mnt/tab\t5");
        assert_eq!(unescape("/mnt/nl\\0121x"), "/mnt/nl\n1x");
        // the kernel escapes every backslash, so \134040 is a literal "\040"
        assert_eq!(unescape("/mnt/a\\134040"), "/mnt/a\\040");
        assert_eq!(unescape("/mnt/a\\134\\0407"), "/mnt/a\\ 7");
        let t = Table::parse("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:2 / /mnt/nas\\0401 rw - nfs4 srv:/x rw\n", &["/home/u"]);
        assert!(t.is_blocking("/mnt/nas 1/proj"));
        assert!(!t.is_blocking("/mnt/nas/proj"));
    }

    #[test]
    fn no_mount_table_means_nothing_is_skipped() {
        let t = Table::parse("", &["/home/u"]);
        assert!(!t.is_blocking("/mnt/nas/proj"));
    }
}
