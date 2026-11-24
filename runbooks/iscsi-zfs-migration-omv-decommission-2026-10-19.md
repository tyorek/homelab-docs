# F: iSCSI disk: tgt -> LIO -> ZFS on the 990 PRO, OMV `nas` decommissioned (2026-10-18/19)

**Initiator:** desktop-01, 192.168.5.9 (VLAN 5, Intel 82599 "Ethernet 3"), `iqn.1991-05.com.microsoft:desktop-01.home.arpa`
**Target now:** pve (Proxmox host), LIO, `iqn.2026-10.local.homelab.pve:diska`, portal 192.168.5.13:3260
**Backing store now:** zvol `hot2/diska` on the Samsung 990 PRO 2TB (`nvme-Samsung_SSD_990_PRO_2TB_SXXXXXXXXXXXXXX`)
**Volume:** F: "DiskA", NTFS inside BitLocker, 1 TiB (game library)

## Final state (verified 2026-10-19 12:15)

| Layer | State |
|---|---|
| Windows | Disk `LIO-ORG diska`, MediaType **SSD**, BusType iSCSI. F: Healthy, 575.75 GB free of 1023.98 GB. BitLocker auto-unlocked through both target swaps. Session persistent; `pve:diska` is the only persistent target. |
| Network | pve `vmbr0.5` = 192.168.5.13/28, MTU 9000, no gateway, IPv6 RAs ignored. Workstation NIC jumbo (NlMtu 9000). `ping -f -l 8972 192.168.5.13` passes. Host default route unchanged (192.168.99.1 via vmbr1.99). |
| LIO | Block backstore `diska` -> `/dev/zvol/hot2/diska`, `is_nonrot=1 emulate_tpu=1 emulate_tpws=1`. One ACL (the workstation), mapped LUN 0, no CHAP. Single portal 192.168.5.13:3260 (default 0.0.0.0 portal deleted). Config in `/etc/rtslib-fb-target/saveconfig.json`, restored at boot by `rtslib-fb-targetctl`. |
| Write cache | The zvol reports `write back` and LIO passes that through, so Windows sends flushes and ZFS commits each one. `emulate_write_cache=1` returns EINVAL on a block backstore; that's expected. The "write-thru" label in `targetcli ls` is the unused emulation flag. |
| ZFS pool | `hot2`: single disk, `ashift=12`, `autotrim=on`, `compression=lz4`, `atime=off`. |
| zvol | `hot2/diska`: sparse, volsize 1T (byte-identical to the old LUN), `volblocksize=16K`. used 451G, logicalused 449G, ratio 1.00x (BitLocker ciphertext doesn't compress; lz4 stays on so all-zero blocks are stored as holes). |
| Snapshot | `hot2/diska@migrated-2026-10-19` |
| ARC | `zfs_arc_max` = 8 GiB, set live and in `/etc/modprobe.d/zfs.conf`; initramfs rebuilt for all kernels. |
| TRIM | Windows UNMAP -> LIO -> zvol frees blocks -> autotrim -> 990 PRO. |

## Phase 1 (2026-10-18): Windows saw the LUN as an HDD

Starting point: OMV VM 109 (`omv` in Proxmox, hostname `nas`, 192.168.5.11) served the LUN with tgt from OMV's iSCSI plugin.

```
<target iqn.2026-05.local.homelab.nas:diska>
backing-store /srv/dev-disk-by-uuid-2c75dc78-c850-40d3-9f27-fb1d94f9866e/SSDShare/targetdiskA
bs-type rdwr
write-cache on
</target>
```

There was no `initiator-address`/`initiator-name` line, so any initiator that could reach 3260 could log in. The image was a 1 TiB file, fully allocated (1015G), on OMV's sdd1, a VM disk on `externalhot3` (the Crucial X9 Pro USB SSD).

Why Windows said HDD: Windows reads the rotation rate from the SCSI Block Device Characteristics VPD page. QEMU presents disks as rotational unless SSD emulation is set, and tgt doesn't report a rotation rate at all.

Changes:
- Proxmox: SSD emulation and Discard on OMV's data disk.
- OMV: iSCSI service disabled in the web UI (not systemctl, so salt doesn't re-enable it). `targetcli-fb` installed. Fileio backstore with `write_back=true` (same cache model as tgt's `write-cache on`), `is_nonrot=1 emulate_tpu=1 emulate_tpws=1`, same IQN, and an ACL for the workstation. LIO refuses logins without an ACL, so this also closed the open target.

Results: Windows MediaType SSD. `Optimize-Volume -ReTrim` trimmed 575.73 GB. OMV's first `fstrim` reported 1.3 TiB (ext4 counts every free block on the first pass after mount). The image's allocation went from 1015G to 449G, and sdd1 went from 57% to 25%.

## Phase 2 (2026-10-19): ZFS zvol on the 990 PRO, served from the host

What prompted it: the "SSD" under the LUN turned out to be the X9 Pro over USB (UAS, 10 Gbps link, discard passed through, no resets in dmesg). Healthy, but USB latency. Meanwhile the 990 PRO sat empty as the `hot2` directory storage. hot1 (Crucial P310) is unchanged.

### Retire the hot2 directory storage and wipe the disk

The pre-checks found no files on hot2, no VM/CT/backup-job references, and the mount came from fstab line 8 (`/dev/disk/by-label/hot2`).

```bash
pvesm remove hot2
umount /mnt/hot2
sed -i '\#^/dev/disk/by-label/hot2#d' /etc/fstab
systemctl daemon-reload
wipefs -a /dev/nvme1n1p1
wipefs -a /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_SXXXXXXXXXXXXXX
```

### Pool, zvol, ARC cap (ZFS 2.4.4-pve1)

```bash
zpool create -o ashift=12 -o autotrim=on -O compression=lz4 -O atime=off hot2 /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_SXXXXXXXXXXXXXX
zfs create -s -V 1T -o volblocksize=16K hot2/diska
echo "options zfs zfs_arc_max=8589934592" > /etc/modprobe.d/zfs.conf
echo 8589934592 > /sys/module/zfs/parameters/zfs_arc_max
update-initramfs -u -k all
```

Why these settings:
- `autotrim=on` is what turns ZFS's internal frees into TRIMs to the SSD.
- 16K volblocksize balances NTFS's 4K random writes against throughput (64K amplifies them).
- The ARC cap exists because root is on LVM, so the installer never set one; uncapped, the ARC grows to half of the 64 GB and competes with the VMs.

### Copy the data (F: offline 11:39-12:09, copy itself 519 s)

1. Windows: `Get-Disk | ? BusType -eq iSCSI | Set-Disk -IsOffline $true`
2. OMV: `systemctl stop rtslib-fb-targetctl` (unloads the target; the saved config stays).
3. pve: `qm set 109 --scsi20 /dev/zvol/hot2/diska,discard=on,ssd=1` (raw-path attach, root only).
4. OMV: the only exactly-1-TiB disk was `/dev/sde`, then:
   `dd if=/srv/dev-disk-by-uuid-2c75dc78-c850-40d3-9f27-fb1d94f9866e/SSDShare/targetdiskA of=/dev/sde bs=1M conv=sparse,fsync status=progress`.
   1,099,511,627,776 bytes in 519 s (2.1 GB/s average). The holes cost nothing, so the USB SSD's read speed set the pace.
5. OMV: `partprobe; lsblk -f` showed `sde1` (Microsoft reserved) and `sde2` BitLocker. That is the integrity check, since the volume is encrypted.
6. pve: `qm set 109 --delete scsi20` (removes the raw path from the VM config only).

### Host interface on VLAN 5

`vmbr0` is the VLAN-aware bridge used for guest VLANs; the host had no address on VLAN 5. Added a host VLAN interface:

```
auto vmbr0.5
iface vmbr0.5 inet static
        address 192.168.5.13/28
        mtu 9000
        post-up echo 0 > /proc/sys/net/ipv6/conf/vmbr0.5/accept_ra
```

There is no gateway on purpose. The workstation is on the same /28, so iSCSI never crosses the router, and a second default route (from DHCP or IPv6 RAs) would pull the host's management traffic onto VLAN 5. Static rather than DHCP because the initiator's portal is configured by IP. MAC 02:00:5e:de:32:c0 (inherited from vmbr0). `pve-firewall` is disabled, so no 3260 rule was needed.

### LIO on the host

```bash
apt install -y targetcli-fb
systemctl enable --now rtslib-fb-targetctl
IQN=iqn.2026-10.local.homelab.pve:diska
targetcli /backstores/block create name=diska dev=/dev/zvol/hot2/diska
targetcli /backstores/block/diska set attribute is_nonrot=1 emulate_tpu=1 emulate_tpws=1
targetcli /iscsi create $IQN
targetcli /iscsi/$IQN/tpg1/luns create /backstores/block/diska
targetcli /iscsi/$IQN/tpg1/acls create iqn.1991-05.com.microsoft:desktop-01.home.arpa
targetcli /iscsi/$IQN/tpg1/portals delete 0.0.0.0 3260
targetcli /iscsi/$IQN/tpg1/portals create 192.168.5.13 3260
targetcli saveconfig
```

OMV's LIO was disabled at boot (`systemctl disable rtslib-fb-targetctl`) so two targets could never serve the same data.

### Windows cutover

```powershell
New-IscsiTargetPortal -TargetPortalAddress 192.168.5.13
Connect-IscsiTarget -NodeAddress iqn.2026-10.local.homelab.pve:diska -TargetPortalAddress 192.168.5.13 -IsPersistent $true
Get-Disk | ? BusType -eq iSCSI | Set-Disk -IsOffline $false
iscsicli RemovePersistentTarget ROOT\ISCSIPRT\0000_0 iqn.2026-05.local.homelab.nas:diska * 192.168.5.11 3260
```

`Unregister-IscsiSession` fails with HRESULT 0xefff0042 for a session that isn't connected; `iscsicli RemovePersistentTarget` works.

## OMV `nas` decommissioned (2026-10-19 12:23)

Inventory before deleting:
- `md0` was **RAID 0**, not a mirror. It sat on two virtual disks, one on each of the host's ST2000LM015 drives (cold1, cold2): 3.7T, with 1.1T used in `[Share]`.
- `[Share]` held VHDX images with part of the Steam library, which was expendable (re-downloadable).
- `[SSDShare]` held only `targetdiskA`. No Docker and no NFS exports.

`qm destroy 109 --purge` deleted the VM, its boot LV and its images on cold1, cold2 and externalhot3, along with its backup/replication entries.

An orphan remained: `/mnt/externalhot3/images/vm-109-disk-0.qcow2`, with 1.83 TiB virtual size, 13.9 GiB allocated, dated Jan 25. It sat directly in `images/` instead of `images/109/`, so Proxmox never listed it and `--purge` skipped it. It was an early copy of OMV's data disk, and it was removed by hand.

Freed: 4 GB of RAM and the VM's vCPUs. The X9 Pro, cold1 and cold2 (about 5.5 TB) are now empty.

## Problems hit and why (for next time)

1. **Placeholders broke commands.** `<windows-initiator-iqn>` and `<n>` were pasted literally; bash and PowerShell read `<` as redirection. Use shell variables or real values.
2. **Windows wouldn't log off the iSCSI session** ("a device on that session is currently being used"). A process held the disk open (likely the disk-temperature widget polling SMART). Taking the disk offline was enough to stop the old target safely.
3. **`VMID=$(qm list | awk '$2=="nas"...')` came back empty.** The VM is named `omv` in Proxmox even though its hostname is `nas`.
4. **Jumbo ping from pve to the workstation failed.** At first this was blamed on Windows Firewall dropping ICMP, but the workstation's 82599 was still at MTU 1500. TCP had been silently negotiating a 1460 MSS, so iSCSI and SMB worked at 1500. Enabling jumbo frames on the NIC fixed it.
5. **`emulate_write_cache=1` -> EINVAL.** This is expected on a block backstore; the zvol's own cache state is used instead (see Final state).
6. **The DHCP reservation for 192.168.5.13 failed with `server=PVE`.** `server=` takes the router's DHCP server instance name for VLAN 5, not a label.
7. **`targetcli` as a normal user** fails on `/var/run/targetcli.lock`; run it as root.

## Still open

- **No copy of F: exists off the 990 PRO.** The old `targetdiskA` was deleted with VM 109, so the only rollback is the snapshot on the same pool. Next: a single-disk pool on cold1 or cold2, plus a nightly snapshot and incremental `zfs send`.
- **Nothing monitors the hot2 pool.** It isn't a Proxmox storage, so the daily digest's API storage check doesn't see it, and there is no SMART coverage for the 990 PRO. Options: a `zpool status -x` / `zpool list` collector, or register hot2 in Proxmox as ZFS storage.
- ~~Verify the DHCP reservation for 192.168.5.13.~~ Verified 2026-10-20: the lease is on dhcp1 with the comment "pve vmbr0.5 iSCSI portal".
- Verify the old portal is gone from Windows (`Get-IscsiTargetPortal` should list only 192.168.5.13).
- Run `Optimize-Volume -DriveLetter F -ReTrim` once against the new target, if it hasn't been run yet.
- Confirm F:'s BitLocker recovery key can be retrieved (ADUC computer object or Microsoft account).
- ~~Remove everything that still points at `nas`.~~ Done 2026-10-20; details are under "nas decommissioned -- 2026-10-19" in `claude-noc-agent-setup.md`.
