#!/bin/sh

# bc other functions require installs, sources.list and update must come first

# variables:
CONF_DIR=./conf
OS=$(lsb_release --codename --short)
PASS=Goodpassword!123
grub_user="2oe"
grub_pass=$(echo -e "$PASS\n$PASS" | grub-mkpasswd-pbkdf2)  # creates encrypted password (same as $PASS)

# helper functions:

# usage: if [ $(chkPkg $name) -eq 0]; then....
# returns 1 if installed and 0 if not
chkPkg() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -c "ok installed"
}

# main functions:

aptCfg() {
  if [ "$OS" = "xenial" ]; then
    cp -p /etc/apt/sources.list /etc/apt/sources.list.bak
    cp $CONF_DIR/sources.list-$OS
  elif [ "$OS" = "trusty" ]; then
    cp -p /etc/apt/sources.list /etc/apt/sources.list.bak
    cp $CONF_DIR/sources.list-$OS
  elif [ "$OS" = "jessie" ]; then
    cp -p /etc/apt/sources.list /etc/apt/sources.list.bak
    cp $CONF_DIR/sources.list-$OS
  else
    echo OS version not recognized. Script only works for Ubuntu 14.04, 16.04, and Debian 8.
  fi

  apt-get update
  apt-get install --reinstall coreutils
}

autoUpgrade() {
  apt-get install -y unattended-upgrades
  cp -p /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades.bak
  cp -p /etc/apt/apt.conf.d/50auto-upgrades /etc/apt/apt.conf.d/50auto-upgrades.bak
  cp $CONF_DIR/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
  cp $CONF_DIR/50auto-upgrades /etc/apt/apt.conf.d/50auto-upgrades
}

passwdPol() {
  # pam
  apt-get install -y libpam-cracklib
  cp -p /etc/pam.d/common-auth /etc/pam.d/common-auth.bak
  cp -p /etc/pam.d/common-password /etc/pam.d/common-password.bak
  cp $CONF_DIR/common-auth /etc/pam.d/common-auth
  if [ $(chkPkg libpam-cracklib) -eq 0 ]; then
    cp $CONF_DIR/common-password /etc/pam.d/common-password
  else
    echo "libpam-cracklib failed to install, common-password not configured" >> error.log
  fi

  cp -p /etc/login.defs /etc/login.defs.bak
  cp $CONF_DIR/login.defs /etc/login.defs

  cp -p /etc/default/useradd /etc/default/useradd.bak
  cp $CONF_DIR/useradd /etc/default/useradd
}

lightdmPol() {
  if [ $(chkPkg lightdm) -eq 1 ]; then
    cp -p /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.bak
    cp $CONF_DIR/lightdm.conf /etc/lightdm/lightdm.conf 
  elif [ $(chkPkg gdm3) -eq 1 ]; then
    cp -p /etc/gdm3/greeter.dconf-defaults /etc/gdm3/greeter.dconf-defaults.bak
    cp -p /etc/gdm3/custom.conf /etc/gdm3/custom.conf.bak
    #cp $CONF_DIR/greeter.dconf-defaults /etc/gdm3/greeter.dconf-defaults
    #cp $CONF_DIR/custom.conf /etc/gdm3/custom.conf

    sed -i 's/^# disable-user-.*/disable-user-list=true/' /etc/gdm3/greeter.dconf-defaults
    sed -i 's/^# disable-restart-.*/disable-restart-buttons=true/' /etc/gdm3/greeter.dconf-defaults
    sed -i 's/^#  AutomaticLoginEnable.*/AutomaticLoginEnable = false/' /etc/gdm3/custom.conf
  fi
}

sshPol() {
  if [ $(chkPkg openssh-server) -eq 1 ]; then
    cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    cp $CONF_DIR/sshd_config /etc/ssh/sshd_config

    systemctl restart sshd.service    # ubuntu 14 tho
  fi
}

sysctlPol() {
  cp -p /etc/sysctl.conf /etc/sysctl.conf.bak
  cp $CONF_DIR/sysctl.conf /etc/sysctl.conf

  sysctl -p
}

perms() {
  chmod 640 /etc/shadow

}

firewall() {
  apt-get install -y ufw
  yes | ufw reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw logging on
  ufw logging high
  ufw allow 222   # SSH port
  ufw enable
}

users() {
  getent passwd | white IFS=: read -r name password uid gid gecos home shell; do
    if [ "$uid" -eq 0 ]; then
      # change UID of UID 0 user (non-root)
      if [ "$name" != "root" ]; then
        # generates new UID and checks if it is in use
        newUID=$(shuf -i 1000-60000 -n 1)
        while [ $(getent passwd $newUID) -eq 0 ]; do
          newUID=$(shuf -i 1000-60000 -n 1)
        done
        usermod -u $newUID $name    # change UID to newly generate id
        find / -user 0 -exec chown -h $name {} \;   # take ownership of files created by user with new UID
      fi
    elif [ "$uid" -ge 1000 ]; then
      chage -m 7 -M 30 $name
      echo -e "$PASS\n$PASS" | passwd $name
    fi
  done
}

misc() {
  # clear rc.local
  echo "exit 0" > /etc/rc.local

  # lock root account
  passwd -l root

  # prevent IP spoofing
  echo "nospoof on" >> /etc/host.conf
  
  # 1.5.4 Disable prelink
  prelink -ua
  apt-get purge -y prelink

  # 1.5.1 Restrict core dumps
cat << EOF > /etc/security/limits.d/custom.conf
* hard core 0
EOF

  # 1.1.20 set sticky bit for world-writable directories
  df --local -P | awk {'if (NR!=1) print $6'} | xargs -I '{}' find '{}' -xdev -type d -perm -0002 2>/dev/null | xargs chmod a+t
}

# SKIPPED
# 1.1.2 - 1.1.16 separate partitions & mount options

# 1.1.1 Disable unused filsystems
unusedFS() {
  touch /etc/modprobe.d/CIS.conf
  for fs in cramfs freevxfs jffs2 hfs hfsplus udf; do
    echo "install $fs /bin/true" >> /etc/modprobe.d/CIS.conf
    rmmod $fs
  done
}

# 1.1.21 disable automounting
automount() {

}

# 1.3 Filesystem Integrity Checking
aideCfg() {
  apt-get install -y aide aide-common

}

# 1.4 Secure Boot
# 1.4.1 Bootloader config perms
# 1.4.2 GRUB password
# Sets username and password to values set at config section of script
grub() {
  chown root:root /boot/grub/grub.cfg
  chmod 0400 /boot/grub/grub.cfg
cat << EOF >> /etc/grub.d/00_header
set superusers="$grub_user"
password_pbkdf2 $grub_user $grub_pass
EOF
  update-grub
}

# 1.6 Mandatory Access Control
# 1.6.2 Configure AppArmor

aptCfg
autoUpgrade
passwdPol
lightdmPol
sshPol
sysctlPol
perms
firewall
users
misc
unusedFS
boot
grub

exit 0
