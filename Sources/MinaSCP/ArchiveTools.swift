import Foundation

enum ArchiveTool: String, CaseIterable { case touch = "Touch", zip = "壓縮成 ZIP…", tar = "壓縮成 tar.gz…", extract = "解壓縮…" }
struct ArchivePlan {
    let script: String
    let staging: String?
    let destination: String?
    let directory: Bool
}
enum ArchiveTools {
    static func required(_ tool: ArchiveTool) -> Set<String> {
        switch tool { case .touch: return ["touch"]; case .zip: return ["zip", "unzip"]; case .tar: return ["tar"]; case .extract: return ["python3"] }
    }
    static func make(_ tool: ArchiveTool, paths: [String], directory: String, destination: String?) throws -> ArchivePlan {
        guard !paths.isEmpty, paths.allSatisfy({ RemotePath.parent($0) == directory && RemotePath.validName(($0 as NSString).lastPathComponent) }) else { throw TransferError.message("請選取同一目錄中的項目") }
        if tool == .touch { return ArchivePlan(script: Shell.inDirectory(directory, command: "touch -c -- " + paths.map(Shell.quote).joined(separator: " ")), staging: nil, destination: nil, directory: false) }
        guard let destination, RemotePath.isSafeMutation(destination), !paths.contains(destination), !paths.contains(where: { destination.hasPrefix($0 + "/") }) else { throw TransferError.message("目的地無效或位於來源內") }
        let staging = RemotePath.join(RemotePath.parent(destination), ".minascp-archive-" + UUID().uuidString + (tool == .zip ? ".zip" : tool == .tar ? ".tar.gz" : ""))
        let names = paths.map { Shell.quote("./" + ($0 as NSString).lastPathComponent) }.joined(separator: " ")
        let command: String
        switch tool {
        case .zip: command = "zip -q -r -y " + Shell.quote(staging) + " " + names + " && unzip -tqq " + Shell.quote(staging)
        case .tar: command = "tar -czf " + Shell.quote(staging) + " -- " + names + " && tar -tzf " + Shell.quote(staging) + " >/dev/null"
        case .extract:
            guard paths.count == 1 else { throw TransferError.message("解壓縮限單一封存檔") }
            command = "python3 -c " + Shell.quote(extractor) + " " + Shell.quote(paths[0]) + " " + Shell.quote(staging)
        case .touch: throw TransferError.message("無效工具")
        }
        return ArchivePlan(script: Shell.inDirectory(directory, command: "test ! -e " + Shell.quote(staging) + " && test ! -L " + Shell.quote(staging) + " &&\n" + command), staging: staging, destination: destination, directory: tool == .extract)
    }
    // Do not use extractall: validate every path/type first, then create regular files exclusively.
    static let extractor = #"""
import os,sys,stat,tarfile,zipfile,posixpath,shutil
source,dest=sys.argv[1:]
if os.path.lexists(dest): raise ValueError('staging already exists')
archive=None
try:
    iszip=zipfile.is_zipfile(source)
    archive=zipfile.ZipFile(source) if iszip else tarfile.open(source, 'r:gz')
    members=archive.infolist() if iszip else archive.getmembers()
    if len(members)>100000: raise ValueError('too many archive entries')
    entries=[]; seen={}; total=0
    for m in members:
        raw=m.filename if iszip else m.name
        if '\x00' in raw or '\\' in raw or raw.startswith('/') or any(p=='..' for p in raw.split('/')): raise ValueError('unsafe path: '+repr(raw))
        name=posixpath.normpath(raw)
        folder=m.is_dir() if iszip else m.isdir()
        if name=='.' and folder: continue
        if name in ('','.','..') or name.startswith('../') or (len(name)>1 and name[1]==':'): raise ValueError('unsafe path')
        if name in seen: raise ValueError('duplicate path: '+name)
        if iszip:
            mode=m.external_attr>>16; kind=stat.S_IFMT(mode)
            if kind not in (0,stat.S_IFDIR,stat.S_IFREG): raise ValueError('links and special files are forbidden')
            if m.flag_bits&1: raise ValueError('encrypted ZIP unsupported')
            size=m.file_size
        else:
            if not (m.isfile() or m.isdir()): raise ValueError('links and special files are forbidden')
            size=m.size
        seen[name]=folder; entries.append((name,folder,size,m)); total+=size
        if total>100*1024**3: raise ValueError('unpacked size exceeds 100 GiB limit')
    for name,folder,_,m in entries:
        p=posixpath.dirname(name)
        while p:
            if p in seen and not seen[p]: raise ValueError('file used as directory')
            p=posixpath.dirname(p)
    free=shutil.disk_usage(os.path.dirname(dest)).free
    if free < total + max(total//10,64*1024**2): raise ValueError('not enough free space')
    os.mkdir(dest,0o700)
    for name,folder,size,m in entries:
        target=os.path.join(dest,*name.split('/'))
        if folder: os.makedirs(target,mode=0o700,exist_ok=True); continue
        os.makedirs(os.path.dirname(target),mode=0o700,exist_ok=True)
        handle=archive.open(m) if iszip else archive.extractfile(m)
        with handle as inp, open(target,'xb') as out:
            copied=0
            while True:
                data=inp.read(1024*1024)
                if not data: break
                copied+=len(data)
                if copied>size: raise ValueError('member size mismatch')
                out.write(data)
            if copied!=size: raise ValueError('truncated member')
        os.chmod(target,0o600)
    print('MINASCP_EXTRACT_OK',len(entries),total)
finally:
    if archive is not None: archive.close()
"""#
}
