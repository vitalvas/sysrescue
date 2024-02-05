#!/usr/bin/env python3

import os
import argparse
import subprocess


class Installer:
    def __init__(self):
        self.args = self._argparse()
        self.mount_point = "/mnt"

    def _argparse(self):
        parser = argparse.ArgumentParser(
            description='Install OS',
            formatter_class=argparse.ArgumentDefaultsHelpFormatter
        )
        parser.add_argument('--os', type=str, help='OS name', default='ubuntu')
        parser.add_argument('--version', type=str, help='OS version', default='22.04')
        parser.add_argument('-d', '--drive', type=str, nargs="+", help='Drive to install OS',  default=self._list_hard_drives())
        parser.add_argument('--rootfs-fstype', type=str, help='Rootfs filesystem type', default='ext4')
        parser.add_argument('--rootfs-size', type=int, help='Rootfs size', default='100%')
        parser.add_argument('--hostname', type=str, help='Hostname', default='localhost')

        return self.parser.parse_args()

    @staticmethod
    def _get_rootfs(os: str, version: str):
        data = {
            "ubuntu/22.04": "http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.3-base-amd64.tar.gz",
        }

        if f"{os}/{version}" in data:
            return data[f"{os}/{version}"]
        
        raise ValueError(f"OS {os} version {version} not found")

    @staticmethod
    def _is_usb_drive(device):
        cmd = ["lsblk", "-no", "TRAN", f"/dev/{device}"]
        try:
            output = subprocess.check_output(cmd).decode().strip()
            return output == "usb"
        except subprocess.CalledProcessError:
            return False

    def _list_hard_drives(self):
        list_drives = os.popen('lsblk -d -o name').read().split('\n')

        drives = [
            entry for entry in list_drives if entry.startswith('sd') or entry.startswith('nvme')
        ]
        
        correct_drives = []
        for row in drives:
            if not self._is_usb_drive(row):
                correct_drives.append(f"/dev/{row}")

        return correct_drives

    def install(self):
                
        print(f"Drives: {self.args.drive}")
        pass

if __name__ == '__main__':
    installer = Installer()
    installer.install()
