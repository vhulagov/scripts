#!/bin/sh -e

find "$1" -type f -iname "*.jpg"|while read file; do \
	printf "./ab."|sed /^[0-9]\{2\}/n
	owner_date="$(printf $(dirname "$file")|sed -n 's,.*\([0-9]\{2\}\).\([0-9]\{2\}\).20\([0-9]\{2\}\).*,\1.\2.20\3,p')"
	create_date="$(stat -c %z "$file"|sed -n 's,\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\).*,\3.\2.\1,p')"
	mod_date="$(stat -c %y "$file"|sed -n 's,\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\).*,\3.\2.\1,p')"
	exif_date="$(exiftool -s3 -createdate -d "%d.%m.%y" "$file")"
	exif_camera="$(exiftool -s3 -model "$file")"
	if [ -n "$owner_date" ]; then
		date="$owner_date"
		source="owner"
	elif [ -n "$exif_date" ]; then
		date="$exif_date"
		source="exif"
	else
		date="$create_date"
		source="create"
	fi
	[ "$(printf "$date"|sed -n 's/.*\..*\.\(.*\)/\1/p')" -le 2000 ] && date="$create_date"
	if [ "$(dirname "$file")" != "./$date" ]; then
		mkdir -p "$date"
		mv "$file" "$date"
		printf "$file $source > $date\n" >> copied_files.txt
	fi	
		
done
