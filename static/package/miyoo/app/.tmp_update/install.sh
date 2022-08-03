#!/bin/sh
installdir=`cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P`
ra_zipfile="/mnt/SDCARD/RetroArch/retroarch.pak"
ra_version_file="/mnt/SDCARD/RetroArch/onion_ra_version.txt"
ra_package_version_file="/mnt/SDCARD/RetroArch/ra_package_version.txt"

main() {
	# init_lcd
	cat /proc/ls
	sleep 0.25
	
	# init charger detection
	gpiodir=/sys/devices/gpiochip0/gpio
	if [ ! -f $gpiodir/gpio59/direction ]; then
		echo 59 > /sys/class/gpio/export
		echo "in" > $gpiodir/gpio59/direction
	fi

	# init backlight
	pwmdir=/sys/class/pwm/pwmchip0
	echo 0 		> $pwmdir/export
	echo 800 	> $pwmdir/pwm0/period
	echo 80 	> $pwmdir/pwm0/duty_cycle
	echo 1 		> $pwmdir/pwm0/enable

	if [ ! -d /mnt/SDCARD/.tmp_update/onionVersion ]; then
		fresh_install 1
		cleanup
		return
	fi

	# Prompt for update or fresh install
	cd $installdir/bin
	./prompt -r -m "Welcome to the Onion installer!\nPlease choose an action:" \
		"Update" \
		"Repair (keep settings)" \
		"Reinstall (reset settings)"
	retcode=$?

	if [ $retcode -eq 255 ]; then
		# Exit (POWER was pressed)
		return
	elif [ $retcode -eq 0 ]; then
		# Update
		update_only
	elif [ $retcode -eq 1 ]; then
		# Repair (keep settings)
		fresh_install 0
	elif [ $retcode -eq 2 ]; then
		# Reinstall (reset settings)
		fresh_install 1
	fi

	cleanup
}

cleanup() {
	echo ":: Cleanup"
	cd $installdir
	rm -f \
		/tmp/.update_msg \
		.installed \
		removed.png \
		removed \
		boot_mod.sh \
		install.sh \
		res/waitingBG.png
}

remove_configs() {
	echo ":: Remove configs"
	rm -rf \
		/mnt/SDCARD/RetroArch/.retroarch/retroarch.cfg
		/mnt/SDCARD/Saves/CurrentProfile/config/*
		/mnt/SDCARD/Saves/GuestProfile/config/*
}

fresh_install() {
	reset_configs=$1
	echo ":: Fresh install (reset: $reset_configs)"

	rm -f /tmp/.update_msg

	# Show installation progress
	cd $installdir
	./bin/installUI &
	sleep 1

	# Backup important stock files
	echo "Backing up files..." >> /tmp/.update_msg
	backup_system

	echo "Uninstalling old system..." >> /tmp/.update_msg

	if [ $reset_configs -eq 1 ]; then
		remove_configs
		maybe_remove_retroarch
	fi

	# Debloat the apps folder
	debloat_apps
	refresh_roms

	# Remove stock folders
	cd /mnt/SDCARD
	rm -rf Emu/* RApp/* Imgs miyoo

	install_core "Installing core..."	
	install_retroarch "Installing RetroArch..."

	echo "Completing installation..." >> /tmp/.update_msg
	if [ $reset_configs -eq 0 ]; then
		restore_ra_config
	fi
	install_configs $reset_configs
	
	echo "Installation complete!" >> /tmp/.update_msg

	touch $installdir/.installed
	sleep 1

	cd /mnt/SDCARD/App/Onion_Manual/
	./launch.sh
	free_mma

	# Launch layer manager
	cd /mnt/SDCARD/App/The_Onion_Installer/ 
	./onionInstaller
	free_mma

	# display turning off message
	cd /mnt/SDCARD/App/Onion_Manual
	./removed

	cd $installdir
	./boot_mod.sh 

	mv -f $installdir/system.json /appconfigs/system.json
}

update_only() {
	echo ":: Update only"

	# Show installation progress
	cd $installdir
	./bin/installUI &
	sleep 1

	install_core "Updating core..."	
	install_retroarch "Updating RetroArch..."
	restore_ra_config
	echo "Update complete! Turning off..." >> /tmp/.update_msg

	touch $installdir/.installed
	sleep 1
}

install_core() {
	echo ":: Install core"
	msg="$1"
	zipfile=$installdir/onion.pak

	if [ ! -f $zipfile ]; then
		return
	fi

	rm -f $installdir/updater

	echo "$msg 0%" >> /tmp/.update_msg

	# Onion core installation / update
	unzip_progress "$zipfile" "$msg" /mnt/SDCARD

	if [ $? -ne 0 ]; then
		touch $installdir/.installFailed
		echo Onion - installation failed
		exit 0
	fi

	rm -f $zipfile
}

install_retroarch() {
	echo ":: Install RetroArch"

	msg="$1"
	install_ra=1

	# An existing version of Onion's RetroArch exist
	if [ -f $ra_version_file ] && [ -f $ra_package_version_file ]; then
		current_ra_version=`cat $ra_version_file`
		package_ra_version=`cat $ra_package_version_file`

		# Skip installation if current version is up-to-date
		if [ $(version $current_ra_version) -ge $(version $package_ra_version) ]; then
			echo "   - Skip installing RetroArch"
			install_ra=0
		fi

		if [ $install_ra -eq 1 ] && [ -f $ra_zipfile ]; then
			# Backup old RA configuration
			cd /mnt/SDCARD/RetroArch
			mv .retroarch/retroarch.cfg /mnt/SDCARD/Backup/
		fi
	fi

	# Install RetroArch only if necessary
	if [ $install_ra -eq 1 ] && [ -f $ra_zipfile ]; then
		echo "$msg 0%" >> /tmp/.update_msg

		# Remove old RetroArch before unzipping
		maybe_remove_retroarch
		
		# Install RetroArch
		unzip_progress "$ra_zipfile" "$msg" /mnt/SDCARD
		
		if [ $? -ne 0 ]; then
			touch $installdir/.installFailed
			echo RetroArch - installation failed
			exit 0
		fi
	fi

	rm -f $ra_zipfile $ra_package_version_file
}

maybe_remove_retroarch() {
	if [ -f $ra_zipfile ]; then
		cd /mnt/SDCARD/RetroArch
		remove_everything_except `basename $ra_zipfile`
	fi
}

restore_ra_config() {
	echo ":: Restore RA config"
	cfg_file=/mnt/SDCARD/Backup/retroarch.cfg
	if [ -f $cfg_file ]; then
		mv -f $cfg_file /mnt/SDCARD/RetroArch/.retroarch/
	fi
}

install_configs() {
	reset_configs=$1
	zipfile=$installdir/config/configs.pak

	echo ":: Install configs (reset: $reset_configs)"

	if [ ! -f $zipfile ]; then
		return
	fi

	cd /mnt/SDCARD
	if [ $reset_configs -eq 1 ]; then
		# Overwrite all default configs
		unzip -oq $zipfile
	else
		# Extract config files without overwriting any existing files
		unzip -nq $zipfile
	fi
}

check_firmware() {
	echo ":: Check firmware"
	if [ ! -f /customer/lib/libpadsp.so ]; then
		cd $installdir
		./removed
		reboot
		exit 0
	fi
}

backup_system() {
	echo ":: Backup system"
	old_ra_dir=/mnt/SDCARD/RetroArch/.retroarch

	# Move BIOS files from stock location
	if [ -d $old_ra_dir/system ] ; then
		mkdir -p /mnt/SDCARD/BIOS
		cp -R $old_ra_dir/system/. /mnt/SDCARD/BIOS/
	fi

	# Backup old saves
	if [ -d $old_ra_dir/saves ] ; then
		mkdir -p /mnt/SDCARD/Backup/saves
		cp -R $old_ra_dir/saves/. /mnt/SDCARD/Backup/saves/
	fi	

	# Backup old states
	if [ -d $old_ra_dir/states ] ; then
		mkdir -p /mnt/SDCARD/Backup/states
		cp -R $old_ra_dir/states/. /mnt/SDCARD/Backup/states/
	fi

	# Themes
	if [ -d /mnt/SDCARD/Themes ]; then
		mv -f /mnt/SDCARD/Themes/* /mnt/SDCARD/Backup/Themes
	fi

	# Imgs
	if [ -d /mnt/SDCARD/Imgs ]; then
		mv -f /mnt/SDCARD/Imgs/* /mnt/SDCARD/Backup/Imgs
	fi
}

debloat_apps() {
	echo ":: Debloat apps"
	cd /mnt/SDCARD/App
	rm -rf \
		Commander_CN \
		power \
		RetroArch \
		swapskin \
		Pal \
		OpenBor \
		Onion_Manual \
		PlayActivity \
		Retroarch \
		The_Onion_Installer
}

refresh_roms() {
	echo ":: Refresh roms"
	# Force refresh the rom lists
	if [ -d /mnt/SDCARD/Roms ] ; then
		cd /mnt/SDCARD/Roms
		find . -type f -name "*.db" -exec rm -f {} \;
	fi
}

version() {
	echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }';
}

remove_everything_except() {
	find * .* -maxdepth 0 -not -name "$1" -exec rm -rf {} \;
}

unzip_progress() {
    zipfile="$1"
	msg="$2"
    dest="$3"
    total=`unzip -l "$zipfile" | tail -1 | grep -Eo "([0-9]+) files" | sed "s/[^0-9]*//g"`

	echo "   - Extract '$zipfile' ($total files) into $dest"

    unzip -o "$zipfile" -d "$dest" | awk -v total="$total" -v out="/tmp/.update_msg" -v msg="$msg" 'BEGIN { cnt = 0; l = 0; printf "" > out; }{
        p = int(cnt * 100 / total);
        if (p != l) {
            printf "%s %3.0f%%\n", msg, p >> out;
            close(out);
            l = p;
        }
        cnt += 1;
    }'

    echo "$msg 100%" >> /tmp/.update_msg
}

free_mma() {
	/mnt/SDCARD/.tmp_update/bin/freemma
}

main
sync
reboot
sleep 10