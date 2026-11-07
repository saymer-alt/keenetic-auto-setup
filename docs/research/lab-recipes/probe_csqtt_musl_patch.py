# Contains a small CSQTT code fragment for a noncommercial lab ABI probe.
# Required Notice: Copyright 2026 amurcanov.
# Required Notice: Commercial use of CSQTT requires a separate written license from the licensor.
# Required Notice: Redistributions and derivative works must retain attribution to the original CSQTT project and these notices.
# Original: https://github.com/amurcanov/csqtt (71712b07dbabe16fa43f5a248dc69e1ab9f3a270)
# Terms: https://polyformproject.org/licenses/noncommercial/1.0.0
import difflib,hashlib,json,pathlib,shutil,subprocess
base=pathlib.Path(__file__).resolve().parent;lab=base/'lab'/'csqtt';probe=lab/'port-probe';probe.mkdir(exist_ok=True)
src=base/'repos'/'amurcanov__csqtt'
for name in ['rust-client','shared']:
    if not (probe/name).exists():shutil.copytree(src/name,probe/name)
p=probe/'rust-client'/'udp_batch.rs';before=(src/'rust-client'/'udp_batch.rs').read_text(encoding='utf-8')
after=before.replace('libc::recvmmsg(fd, messages, count, flags, timeout)','libc::recvmmsg(fd, messages, count, flags as _, timeout)').replace('libc::sendmmsg(fd, messages, count, flags)','libc::sendmmsg(fd, messages, count, flags as _)')
old='''        libc::mmsghdr {
            msg_hdr: libc::msghdr {
                msg_name: ptr::null_mut(),
                msg_namelen: 0,
                msg_iov: iovec,
                msg_iovlen: 1,
                msg_control: ptr::null_mut(),
                msg_controllen: 0,
                msg_flags: 0,
            },
            msg_len: 0,
        }'''
new='''        // Lab portability probe: libc POD fields permit all-zero initialization.
        // This initializes musl's private padding without naming those fields.
        let mut header: libc::mmsghdr = unsafe { std::mem::zeroed() };
        header.msg_hdr.msg_iov = iovec;
        header.msg_hdr.msg_iovlen = 1;
        header'''
assert old in after;after=after.replace(old,new);p.write_text(after,encoding='utf-8',newline='\n')
patch=''.join(difflib.unified_diff(before.splitlines(keepends=True),after.splitlines(keepends=True),fromfile='a/rust-client/udp_batch.rs',tofile='b/rust-client/udp_batch.rs'))
(lab/'musl-port-probe.patch').write_text(patch,encoding='utf-8')
print('Lab-only three-site musl ABI patch; rebuilding isolated copied client.',flush=True)
script=(base/'build_csqtt_arm64.py').read_text(encoding='utf-8').replace("linux(base/'repos'/'amurcanov__csqtt'/'rust-client')","linux(probe/'rust-client')").replace("'arm64-build.log'","'arm64-patched-build.log'").replace("'arm64-result.json'","'arm64-patched-result.json'")
exec(compile(script,'lab-build-arm64-patched','exec'))
r=json.loads((lab/'arm64-patched-result.json').read_text(encoding='utf-8'));r.update(scope='Lab-only copied source plus three-site libc ABI patch. Not applied to KAS or upstream. No real router/network acceptance.',patch_sha256=hashlib.sha256(patch.encode()).hexdigest(),patch=patch,upstream_source_file_sha256=hashlib.sha256(before.encode()).hexdigest(),patched_source_file_sha256=hashlib.sha256(after.encode()).hexdigest())
(lab/'arm64-patched-result.json').write_text(json.dumps(r,indent=2),encoding='utf-8')
