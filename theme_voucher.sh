#!/bin/sh
#Copyright (C) The openNDS Contributors 2004-2023
#Copyright (C) BlueWave Projects and Services 2015-2024
#Copyright (C) Francesco Servida 2023
#This software is released under the GNU GPL license.
#
# Warning - shebang sh is for compatibliity with busybox ash (eg on OpenWrt)
# This must be changed to bash for use on generic Linux
#

# Title of this theme:
title="theme_voucher"

# functions:

generate_splash_sequence() {
	login_with_voucher
}

header() {
# Define a common header html for every page served
	gatewayurl=$(printf "${gatewayurl//%/\\x}")
	echo "<!DOCTYPE html>
		<html>
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<link rel=\"shortcut icon\" href=\"/images/splash.jpg\" type=\"image/x-icon\">
		<link rel=\"stylesheet\" type=\"text/css\" href=\"/splash.css\">
		<title>$gatewayname</title>
		</head>
		<body>
		<div class=\"offset\">
		<div class=\"insert\" style=\"max-width:100%;\">
	"
}

footer() {
	# Define a common footer html for every page served
	year=$(date +'%Y')
	echo "
		<hr>
		<div style=\"font-size:0.5em;\">
			<br>
			<img style=\"height:60px; width:60px; float:left;\" src=\"$gatewayurl""$imagepath\" alt=\"Splash Page: For access to the Internet.\">
			&copy; Portal: BlueWave Projects and Services 2015 - $year<br>
			<br>
			Portal Version: $version
			<br><br><br><br>
		</div>
		</div>
		</div>
		</body>
		</html>
	"

	exit 0
}

login_with_voucher() {
	# This is the simple click to continue splash page with no client validation.
	# The client is however required to accept the terms of service.

	if [ "$tos" = "accepted" ]; then
		#echo "$tos <br>"
		#echo "$voucher <br>"
		voucher_validation
		footer
	fi

	voucher_form
	footer
}

check_voucher() {

	# Strict Voucher Validation for shell escape prevention - Only alphanumeric (and dash character) allowed.
	if validation=$(echo -n $voucher | grep -E "^[a-zA-Z0-9-]{9}$"); then
		#echo "Voucher Validation successful, proceeding"
		: #no-op
	else
		#echo "Invalid Voucher - Voucher must be alphanumeric (and dash) of 9 chars."
		return 1
	fi

	##############################################################################################################################
	# WARNING
	# The voucher roll is written to on every login
	# If its location is on router flash, this **WILL** result in non-repairable failure of the flash memory
	# and therefore the router itself. This will happen, most likely within several months depending on the number of logins.
	#
	# The location is set here to be the same location as the openNDS log (logdir)
	# By default this will be on the tmpfs (ramdisk) of the operating system.
	# Files stored here will not survive a reboot.

	voucher_roll="/etc/opennds/vouchers.txt"

	#
	# In a production system, the mountpoint for logdir should be changed to the mount point of some external storage
	# eg a usb stick, an external drive, a network shared drive etc.
	#
	# See "Customise the Logfile location" at the end of this file
	#
	##############################################################################################################################

	# --- SHAMIM MAC-BINDING PATCH ---
	# Record format is now 8 comma separated fields:
	#   CODE,rate_down,rate_up,quota_down,quota_up,time_limit_minutes,first_punched_timestamp,bound_mac
	# Field 8 (bound_mac) is empty until the voucher is first used. Old 7-field records
	# (created before this patch, or by an older panel) are still fully supported - they
	# are simply treated as "not yet bound to any device" and get bound on next use.

	# Anchored, exact match on the code field only (avoids accidental substring matches).
	output=$(grep -E "^$voucher," "$voucher_roll" | head -n 1)

	if [ -z "$output" ]; then
		echo "No Voucher Found - Retry <br>"
		return 1
	fi

	current_time=$(date +%s)

	voucher_token=$(echo "$output" | awk -F',' '{print $1}')
	voucher_rate_down=$(echo "$output" | awk -F',' '{print $2}')
	voucher_rate_up=$(echo "$output" | awk -F',' '{print $3}')
	voucher_quota_down=$(echo "$output" | awk -F',' '{print $4}')
	voucher_quota_up=$(echo "$output" | awk -F',' '{print $5}')
	voucher_time_limit=$(echo "$output" | awk -F',' '{print $6}')
	voucher_first_punched=$(echo "$output" | awk -F',' '{print $7}')
	voucher_bound_mac=$(echo "$output" | awk -F',' '{print $8}')

	# Guard against blank/garbled fields
	case "$voucher_first_punched" in
		''|*[!0-9]*) voucher_first_punched=0 ;;
	esac

	# Set limits according to voucher
	upload_rate=$voucher_rate_up
	download_rate=$voucher_rate_down
	upload_quota=$voucher_quota_up
	download_quota=$voucher_quota_down

	# Normalise MAC addresses for a safe, case-insensitive comparison
	client_mac_norm=$(echo "$clientmac" | tr 'A-Z' 'a-z')
	bound_mac_norm=$(echo "$voucher_bound_mac" | tr 'A-Z' 'a-z')

	if [ "$voucher_first_punched" -eq 0 ]; then
		#echo "First Voucher Use - binding to $clientmac"
		# "Punch" the voucher: set first-use timestamp AND lock it to this MAC address.
		voucher_expiration=$(($current_time + $voucher_time_limit * 60))
		sessiontimeout=$voucher_time_limit

		newline=$(echo "$output" | awk -F',' -v now="$current_time" -v mac="$clientmac" \
			'BEGIN{OFS=","} {print $1,$2,$3,$4,$5,$6,now,mac}')
		esc_new=$(printf '%s' "$newline" | sed -e 's/[\/&]/\\&/g')
		sed -i -r "s#^$voucher,.*#$esc_new#" "$voucher_roll"
		return 0
	else
		if [ -z "$bound_mac_norm" ] || [ "$bound_mac_norm" = "$client_mac_norm" ]; then
			#echo "Voucher Already Used - same device, checking validity <br>"
			# Current timestamp <= than Punch Timestamp + Validity (minutes) * 60 secs/minute
			voucher_expiration=$(($voucher_first_punched + $voucher_time_limit * 60))

			if [ "$current_time" -le "$voucher_expiration" ]; then
				time_remaining=$(( ($voucher_expiration - $current_time) / 60 ))
				#echo "Voucher is still valid - You have $time_remaining minutes left <br>"
				sessiontimeout=$time_remaining

				# Legacy record with no MAC bound yet (created before this patch) - bind it now.
				if [ -z "$bound_mac_norm" ]; then
					newline=$(echo "$output" | awk -F',' -v mac="$clientmac" \
						'BEGIN{OFS=","} {print $1,$2,$3,$4,$5,$6,$7,mac}')
					esc_new=$(printf '%s' "$newline" | sed -e 's/[\/&]/\\&/g')
					sed -i -r "s#^$voucher,.*#$esc_new#" "$voucher_roll"
				fi
				return 0
			else
				#echo "Voucher has expired, please try another one <br>"
				sed -i -r "/^$voucher,/d" "$voucher_roll"
				return 1
			fi
		else
			#echo "Voucher is bound to a different device - reject <br>"
			echo "<big-red>এই ভাউচার কোডটি ইতিমধ্যে অন্য একটি ডিভাইসে ব্যবহৃত হয়েছে। এই কোড দিয়ে শুধু সেই ডিভাইসেই সংযোগ করা যাবে।</big-red>"
			return 1
		fi
	fi

	# Should not get here
	return 1
}

voucher_validation() {
	originurl=$(printf "${originurl//%/\\x}")

	check_voucher
	if [ $? -eq 0 ]; then
		#echo "Voucher is Valid, click Continue to finish login<br>"

		# Refresh quotas with ones imported from the voucher roll.
		quotas="$sessiontimeout $upload_rate $download_rate $upload_quota $download_quota"
		# Set voucher used (useful if for accounting reasons you track who received which voucher)
		userinfo="$title - $voucher"

		# Authenticate and write to the log - returns with $ndsstatus set
		auth_log

		# output the landing page - note many CPD implementations will close as soon as Internet access is detected
		# The client may not see this page, or only see it briefly
		auth_success="
			<p>
				<big-red>
					You are now logged in and have been granted access to the Internet.
				</big-red>
				<hr>
			</p>
			This voucher is valid for $sessiontimeout minutes.
			<hr>
			<p>
				<italic-black>
					You can use your Browser, Email and other network Apps as you normally would.
				</italic-black>
			</p>
			<p>
				Your device originally requested <b>$originurl</b>
				<br>
				Click or tap Continue to go to there.
			</p>
			<form>
				<input type=\"button\" VALUE=\"Continue\" onClick=\"location.href='$originurl'\" >
			</form>
			<hr>
		"
		auth_fail="
			<p>
				<big-red>
					Something went wrong and you have failed to log in.
				</big-red>
				<hr>
			</p>
			<hr>
			<p>
				<italic-black>
					Your login attempt probably timed out.
				</italic-black>
			</p>
			<p>
				<br>
				Click or tap Continue to try again.
			</p>
			<form>
				<input type=\"button\" VALUE=\"Continue\" onClick=\"location.href='$originurl'\" >
			</form>
			<hr>
		"

		if [ "$ndsstatus" = "authenticated" ]; then
			echo "$auth_success"
		else
			echo "$auth_fail"
		fi
	else
		echo "<big-red>Voucher is not Valid, click Continue to restart login<br></big-red>"
		echo "
			<form>
				<input type=\"button\" VALUE=\"Continue\" onClick=\"location.href='$originurl'\" >
			</form>
		"
	fi

	# Serve the rest of the page:
	read_terms
	footer
}

voucher_form() {
	# Define a click to Continue form

	# From openNDS v10.2.0 onwards, QL code scanning is supported to pre-fill the "voucher" field in this voucher_form page.
	#
	# The QL code must be of the link type and be of the following form:
	#
	# http://[gatewayfqdn]/login?voucher=[voucher_code]
	#
	# where [gatewayfqdn] defaults to status.client (can be set in the config)
	# and [voucher_code] is of course the unique voucher code for the current user

	# Get the voucher code:

	voucher_code=$(echo "$cpi_query" | awk -F "voucher%3d" '{printf "%s", $2}' | awk -F "%26" '{printf "%s", $1}')

	echo "
		<med-blue>
			Welcome!
		</med-blue><br>
		<hr>
		Your IP: $clientip <br>
		Your MAC: $clientmac <br>
		<hr>
		<form action=\"/opennds_preauth/\" method=\"get\">
			<input type=\"hidden\" name=\"fas\" value=\"$fas\"> 
			<input type=\"checkbox\" name=\"tos\" value=\"accepted\" required> I accept the Terms of Service<br>
			Voucher #: <input type=\"text\" name=\"voucher\" value=\"$voucher_code\" required><br>
			<input type=\"submit\" value=\"Connect\" >
		</form>
		<br>
	"

	read_terms
	footer
}

read_terms() {
	#terms of service button
	echo "
		<form action=\"/opennds_preauth/\" method=\"get\">
			<input type=\"hidden\" name=\"fas\" value=\"$fas\">
			<input type=\"hidden\" name=\"terms\" value=\"yes\">
			<input type=\"submit\" value=\"Read Terms of Service   \" >
		</form>
	"
}

display_terms() {
	# This is the all important "Terms of service"
	# Edit this long winded generic version to suit your requirements.
	####
	# WARNING #
	# It is your responsibility to ensure these "Terms of Service" are compliant with the REGULATIONS and LAWS of your Country or State.
	# In most locations, a Privacy Statement is an essential part of the Terms of Service.
	####

	#Privacy
	echo "
		<b style=\"color:red;\">Privacy.</b><br>
		<b>
			By logging in to the system, you grant your permission for this system to store any data you provide for
			the purposes of logging in, along with the networking parameters of your device that the system requires to function.<br>
			All information is stored for your convenience and for the protection of both yourself and us.<br>
			All information collected by this system is stored in a secure manner and is not accessible by third parties.<br>
		</b><hr>
	"

	# Terms of Service
	echo "
		<b style=\"color:red;\">Terms of Service for this Hotspot.</b> <br>
		<b>Access is granted on a basis of trust that you will NOT misuse or abuse that access in any way.</b><hr>
		<b>Please scroll down to read the Terms of Service in full or click the Continue button to return to the Acceptance Page</b>
		<form>
			<input type=\"button\" VALUE=\"Continue\" onClick=\"history.go(-1);return true;\">
		</form>
	"

	# Proper Use
	echo "
		<hr>
		<b>Proper Use</b>
		<p>
			This Hotspot provides a wireless network that allows you to connect to the Internet. <br>
			<b>Use of this Internet connection is provided in return for your FULL acceptance of these Terms Of Service.</b>
		</p>
		<p>
			<b>You agree</b> that you are responsible for providing security measures that are suited for your intended use of the Service.
			For example, you shall take full responsibility for taking adequate measures to safeguard your data from loss.
		</p>
		<p>
			While the Hotspot uses commercially reasonable efforts to provide a secure service,
			the effectiveness of those efforts cannot be guaranteed.
		</p>
		<p>
			<b>You may</b> use the technology provided to you by this Hotspot for the sole purpose
			of using the Service as described here.
			You must immediately notify the Owner of any unauthorized use of the Service or any other security breach.<br><br>
			We will give you an IP address each time you access the Hotspot, and it may change.
			<br>
			<b>You shall not</b> program any other IP or MAC address into your device that accesses the Hotspot.
			You may not use the Service for any other reason, including reselling any aspect of the Service.
			Other examples of improper activities include, without limitation:
		</p>
			<ol>
				<li>
					downloading or uploading such large volumes of data that the performance of the Service becomes
					noticeably degraded for other users for a significant period;
				</li>
				<li>
					attempting to break security, access, tamper with or use any unauthorized areas of the Service;
				</li>
				<li>
					removing any copyright, trademark or other proprietary rights notices contained in or on the Service;
				</li>
				<li>
					attempting to collect or maintain any information about other users of the Service
					(including usernames and/or email addresses) or other third parties for unauthorized purposes;
				</li>
				<li>
					logging onto the Service under false or fraudulent pretenses;
				</li>
				<li>
					creating or transmitting unwanted electronic communications such as SPAM or chain letters to other users
					or otherwise interfering with other user's enjoyment of the service;
				</li>
				<li>
					transmitting any viruses, worms, defects, Trojan Horses or other items of a destructive nature; or
				</li>
				<li>
					using the Service for any unlawful, harassing, abusive, criminal or fraudulent purpose.
				</li>
			</ol>
	"

	# Content Disclaimer
	echo "
		<hr>
		<b>Content Disclaimer</b>
		<p>
			The Hotspot Owners do not control and are not responsible for data, content, services, or products
			that are accessed or downloaded through the Service.
			The Owners may, but are not obliged to, block data transmissions to protect the Owner and the Public.
		</p>
		The Owners, their suppliers and their licensors expressly disclaim to the fullest extent permitted by law,
		all express, implied, and statutary warranties, including, without limitation, the warranties of merchantability
		or fitness for a particular purpose.
		<br><br>
		The Owners, their suppliers and their licensors expressly disclaim to the fullest extent permitted by law
		any liability for infringement of proprietory rights and/or infringement of Copyright by any user of the system.
		Login details and device identities may be stored and be used as evidence in a Court of Law against such users.
		<br>
	"

	# Limitation of Liability
	echo "
		<hr><b>Limitation of Liability</b>
		<p>
			Under no circumstances shall the Owners, their suppliers or their licensors be liable to any user or
			any third party on account of that party's use or misuse of or reliance on the Service.
		</p>
		<hr><b>Changes to Terms of Service and Termination</b>
		<p>
			We may modify or terminate the Service and these Terms of Service and any accompanying policies,
			for any reason, and without notice, including the right to terminate with or without notice,
			without liability to you, any user or any third party. Please review these Terms of Service
			from time to time so that you will be apprised of any changes.
		</p>
		<p>
			We reserve the right to terminate your use of the Service, for any reason, and without notice.
			Upon any such termination, any and all rights granted to you by this Hotspot Owner shall terminate.
		</p>
	"

	# Indemnity
	echo "
		<hr><b>Indemnity</b>
		<p>
			<b>You agree</b> to hold harmless and indemnify the Owners of this Hotspot,
			their suppliers and licensors from and against any third party claim arising from
			or in any way related to your use of the Service, including any liability or expense arising from all claims,
			losses, damages (actual and consequential), suits, judgments, litigation costs and legal fees, of every kind and nature.
		</p>
		<hr>
		<form>
			<input type=\"button\" VALUE=\"Continue\" onClick=\"history.go(-1);return true;\">
		</form>
	"
	footer
}

#### end of functions ####


#################################################
#						#
#  Start - Main entry point for this Theme	#
#						#
#  Parameters set here overide those		#
#  set in libopennds.sh			#
#						#
#################################################

# Quotas and Data Rates
#########################################
# Set length of session in minutes (eg 24 hours is 1440 minutes - if set to 0 then defaults to global sessiontimeout value):
# eg for 100 mins:
# sessiontimeout="100"
#
# eg for 20 hours:
# sessiontimeout=$((20*60))
#
# eg for 20 hours and 30 minutes:
# sessiontimeout=$((20*60+30))
sessiontimeout="0"

# Set Rate and Quota values for the client
# The session length, rate and quota values could be determined by this script, on a per client basis.
# rates are in kb/s, quotas are in kB. - if set to 0 then defaults to global value).
upload_rate="0"
download_rate="0"
upload_quota="0"
download_quota="0"

quotas="$sessiontimeout $upload_rate $download_rate $upload_quota $download_quota"

# Define the list of Parameters we expect to be sent sent from openNDS ($ndsparamlist):
# Note you can add custom parameters to the config file and to read them you must also add them here.
# Custom parameters are "Portal" information and are the same for all clients eg "admin_email" and "location" 
ndscustomparams=""
ndscustomimages=""
ndscustomfiles=""

ndsparamlist="$ndsparamlist $ndscustomparams $ndscustomimages $ndscustomfiles"

# The list of FAS Variables used in the Login Dialogue generated by this script is $fasvarlist and defined in libopennds.sh
#
# Additional custom FAS variables defined in this theme should be added to $fasvarlist here.
additionalthemevars="tos voucher"

fasvarlist="$fasvarlist $additionalthemevars"

# You can choose to define a custom string. This will be b64 encoded and sent to openNDS.
# There it will be made available to be displayed in the output of ndsctl json as well as being sent
#	to the BinAuth post authentication processing script if enabled.
# Set the variable $binauth_custom to the desired value.
# Values set here can be overridden by the themespec file

#binauth_custom="This is sample text sent from \"$title\" to \"BinAuth\" for post authentication processing."

# Encode and activate the custom string
#encode_custom

# Set the user info string for logs (this can contain any useful information)
userinfo="$title"

##############################################################################################################################
# Customise the Logfile location.
##############################################################################################################################
#Note: the default uses the tmpfs "temporary" directory to prevent flash wear.
# Override the defaults to a custom location eg a mounted USB stick.
#mountpoint="/mylogdrivemountpoint"
#logdir="$mountpoint/ndslog/"
#logname="ndslog.log"


# >>> SHAMIM_CUSTOM_PORTAL >>>
scp_load() {
    SCPDIR="${SHAMIM_CFGDIR:-/etc/shamim}"
    BRAND="SHAMIM WiFi"
    PAY_BKASH="01638073621"
    PORTAL_MSG="দ্রুত, নির্ভরযোগ্য ও নিরাপদ ইন্টারনেট সেবা"
    [ -f "$SCPDIR/config" ] && . "$SCPDIR/config"
    [ -n "${BRAND:-}" ] || BRAND="SHAMIM WiFi"
    [ -n "${PAY_BKASH:-}" ] || PAY_BKASH="01638073621"
}

header() {
    scp_load
    cat <<EOF
<!DOCTYPE html>
<html lang="bn">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<meta http-equiv="Cache-Control" content="no-cache,no-store,must-revalidate">
<title>$BRAND</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#fff7fb;color:#4b1732;font-family:Arial,"Noto Sans Bengali",sans-serif}.top{background:linear-gradient(135deg,#e50057,#a90055);color:#fff;padding:20px 16px 28px;overflow:hidden}.shell{max-width:520px;margin:auto}.brand{display:flex;align-items:center;gap:11px}.logo{width:54px;height:54px;border:3px solid #fff;border-radius:12px;display:grid;place-items:center;font-size:31px}.brand b{display:block;font-size:25px;line-height:1}.brand small{display:block;margin-top:6px;opacity:.92}.hero{display:flex;align-items:center;justify-content:space-between;margin-top:20px}.headline{font-weight:900;font-size:35px;line-height:1.12}.headline span{color:#ffd126}.router{position:relative;width:175px;height:100px;background:linear-gradient(#fff,#eaeaea);border-radius:22px 22px 12px 12px;box-shadow:0 15px 22px #65002f66;display:grid;place-items:center;color:#df0058;font-size:50px}.router:before,.router:after{content:"";position:absolute;width:7px;height:98px;background:#fff;border-radius:9px;top:-62px}.router:before{left:25px;transform:rotate(-8deg)}.router:after{right:25px;transform:rotate(8deg)}.benefits{display:grid;grid-template-columns:repeat(4,1fr);gap:7px;margin-top:26px}.benefit{text-align:center;font-size:11px;border-right:1px solid #ffffff55}.benefit:last-child{border:0}.benefit i{display:block;font-style:normal;font-size:25px;margin-bottom:5px}.content{max-width:520px;margin:-14px auto 0;padding:0 12px 25px}.card{background:#fff;border-radius:22px;padding:19px;margin-bottom:14px;box-shadow:0 7px 22px #b5004b18;border:1px solid #f7d8e5}.card h2{margin:0 0 4px;color:#a9004d;font-size:22px}.sub{color:#745363;font-size:13px;margin-bottom:15px}.voucher-input{width:100%;padding:16px;border:2px solid #f1bfd3;border-radius:13px;font-size:20px;text-align:center;letter-spacing:2px;text-transform:uppercase;outline:0}.voucher-input:focus{border-color:#dc0060}.connect{width:100%;margin-top:11px;padding:15px;border:0;border-radius:13px;color:#fff;background:linear-gradient(90deg,#eb005c,#b40058);font-size:19px;font-weight:800}.packages h2{font-size:20px}.pkggrid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.pkg{border:1px solid #f2cbdc;border-radius:17px;text-align:center;overflow:hidden;background:#fff}.pkg.purple{border-color:#ddc8f7}.pkghead{padding:8px;color:#fff;font-size:19px;font-weight:bold;background:linear-gradient(90deg,#ef005d,#c10057)}.purple .pkghead{background:linear-gradient(90deg,#9a00d5,#5c00b7)}.price{font-size:49px;font-weight:900;color:#d60057;padding:15px 5px 6px}.purple .price{color:#7000bd}.price small{font-size:15px}.features{border-top:1px solid #f4dce6;padding:11px 4px;font-size:11px;display:flex;justify-content:space-around;color:#623448}.strip{display:grid;grid-template-columns:repeat(4,1fr);gap:5px;text-align:center;font-size:10px}.strip b{display:block;font-size:22px;margin-bottom:4px}.support{background:linear-gradient(90deg,#b30058,#db0059);color:#fff;border-radius:19px;padding:13px;display:grid;grid-template-columns:1fr 1fr 1fr;text-align:center;font-size:11px}.support b{display:block;font-size:13px;margin-top:4px}.notice{text-align:center;font-size:11px;color:#8a6475;margin-top:12px}big-red,med-blue,italic-black{display:block;text-align:center;margin:8px}big-red{color:#bd0054;font-weight:bold;font-size:18px}hr{border:0;border-top:1px solid #f0d7e2}
</style>
</head>
<body>
<section class="top"><div class="shell">
<div class="brand"><div class="logo">▥</div><div><b>$BRAND</b><small>$PORTAL_MSG</small></div></div>
<div class="hero"><div class="headline">দ্রুত ইন্টারনেট<br><span>নির্ভরতার সাথে</span></div><div class="router">⌁</div></div>
<div class="benefits"><div class="benefit"><i>◉</i>দ্রুত সংযোগ</div><div class="benefit"><i>♢</i>নিরাপদ ব্যবহার</div><div class="benefit"><i>♬</i>২৪/৭ সাপোর্ট</div><div class="benefit"><i>▣</i>সহজ পেমেন্ট</div></div>
</div></section><main class="content">
EOF
}

voucher_form() {
    cat <<EOF
<section class="card">
<h2>🎟 ভাউচার কোড দিন</h2><div class="sub">আপনার ভাউচার কোড দিয়ে ইন্টারনেটে সংযুক্ত হন</div>
<form action="/opennds_preauth/" method="get">
<input type="hidden" name="fas" value="$fas"><input type="hidden" name="tos" value="accepted">
<input class="voucher-input" type="text" name="voucher" value="" maxlength="9" pattern="[a-zA-Z0-9-]{9}" required autocomplete="off" autocapitalize="characters" oninput="this.value=this.value.toUpperCase()" placeholder="ভাউচার কোড লিখুন">
<button class="connect" type="submit">➤ সংযোগ করুন</button>
</form></section>
EOF
}

footer() {
    scp_load
    cat <<EOF
<section class="card packages"><h2>🏷 ইন্টারনেট প্যাকেজ</h2><div class="pkggrid">
<div class="pkg"><div class="pkghead">১৫ দিন</div><div class="price">৫০ <small>টাকা</small></div><div class="features"><span>⚡<br>হাই স্পিড</span><span>♢<br>নিরাপদ</span><span>◷<br>২৪/৭</span></div></div>
<div class="pkg purple"><div class="pkghead">৩০ দিন</div><div class="price">১০০ <small>টাকা</small></div><div class="features"><span>⚡<br>হাই স্পিড</span><span>♢<br>নিরাপদ</span><span>◷<br>২৪/৭</span></div></div>
</div></section>
<section class="card"><div class="strip"><div><b>◉</b>দ্রুত সংযোগ</div><div><b>♢</b>নিরাপদ ব্যবহার</div><div><b>♬</b>২৪/৭ সাপোর্ট</div><div><b>▣</b>সহজ পেমেন্ট</div></div></section>
<section class="support"><div>☘<b>WhatsApp<br>$PAY_BKASH</b></div><div>☎<b>Call Us<br>$PAY_BKASH</b></div><div>♬<b>Support<br>24/7 Available</b></div></section>
<div class="notice">© $BRAND · Voucher WiFi Service</div></main></body></html>
EOF
    exit 0
}
# <<< SHAMIM_CUSTOM_PORTAL <<<
