#!/bin/sh
# fou-autoupdate.sh
# Autoupdater and loader for FOU modules.

REPO="EatPrilosec/ax68u-fou"
MODULE_DIR="/jffs/modules/fou"
SCRIPT_PATH="/jffs/scripts/fou-autoupdate.sh"

install_updater() {
    echo "Installing FOU autoupdater..."
    mkdir -p "$MODULE_DIR"
    
    # Schedule with cru to run every 3 hours
    cru a fou_autoupdate "0 */3 * * * $SCRIPT_PATH"
    
    # Add to services-start if not present
    if [ -f /jffs/scripts/services-start ]; then
        if ! grep -q "fou-autoupdate.sh" /jffs/scripts/services-start; then
            echo "$SCRIPT_PATH" >> /jffs/scripts/services-start
        fi
    else
        echo "#!/bin/sh" > /jffs/scripts/services-start
        echo "$SCRIPT_PATH" >> /jffs/scripts/services-start
        chmod +x /jffs/scripts/services-start
    fi
    
    echo "FOU autoupdater installed and scheduled."
    
    # Run the update logic once to fetch and load modules
    update_and_load
}

update_and_load() {
    # Get current firmware version
    BUILDNO=$(nvram get buildno)
    EXTENDNO=$(nvram get extendno | cut -d'_' -f1)
    
    if [ "$EXTENDNO" = "0" ]; then
        CURRENT_FW="3004.${BUILDNO}"
    else
        CURRENT_FW="3004.${BUILDNO}_${EXTENDNO}"
    fi
    
    # 1. Check for latest release on GitHub
    LATEST_RELEASE=$(curl -sL "https://api.github.com/repos/${REPO}/releases/latest")
    LATEST_TAG=$(echo "$LATEST_RELEASE" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -n "$LATEST_TAG" ]; then
        # Tag format is typically 3004.388.7_fou_module
        LATEST_FW=${LATEST_TAG%_fou_module}
        
        # 2. Download if not already downloaded
        if [ ! -d "${MODULE_DIR}/${LATEST_FW}" ]; then
            echo "Downloading modules for ${LATEST_FW}..."
            mkdir -p "${MODULE_DIR}/${LATEST_FW}"
            
            # Fetch all .ko files available in the release
            echo "$LATEST_RELEASE" | grep '"browser_download_url":' | grep '\.ko"' | sed -E 's/.*"([^"]+)".*/\1/' | while read -r url; do
                filename=$(basename "$url")
                curl -sL "$url" -o "${MODULE_DIR}/${LATEST_FW}/${filename}"
            done
            echo "Downloaded modules successfully."
        fi
    fi

    # 3. Load modules for current FW if not already loaded
    if ! lsmod | grep -q 'fou'; then
        if [ -d "${MODULE_DIR}/${CURRENT_FW}" ]; then
            # Load IPv4 dependencies
            [ -f "${MODULE_DIR}/${CURRENT_FW}/udp_tunnel.ko" ] && insmod "${MODULE_DIR}/${CURRENT_FW}/udp_tunnel.ko" 2>/dev/null
            [ -f "${MODULE_DIR}/${CURRENT_FW}/fou.ko" ] && insmod "${MODULE_DIR}/${CURRENT_FW}/fou.ko" 2>/dev/null
            
            # Load IPv6 dependencies if IPv6 is enabled
            IPV6_SERVICE=$(nvram get ipv6_service)
            if [ -n "$IPV6_SERVICE" ] && [ "$IPV6_SERVICE" != "disabled" ]; then
                [ -f "${MODULE_DIR}/${CURRENT_FW}/ip6_udp_tunnel.ko" ] && insmod "${MODULE_DIR}/${CURRENT_FW}/ip6_udp_tunnel.ko" 2>/dev/null
                [ -f "${MODULE_DIR}/${CURRENT_FW}/fou6.ko" ] && insmod "${MODULE_DIR}/${CURRENT_FW}/fou6.ko" 2>/dev/null
            fi
            
            echo "Loaded modules for firmware ${CURRENT_FW}."
        else
            echo "Modules for current firmware ${CURRENT_FW} not found."
        fi
    fi
    
    # 4. Cleanup old versions, keep current, latest, and one backup (3 total)
    if cd "$MODULE_DIR" 2>/dev/null; then
        FOLDERS=$(ls -td */ 2>/dev/null | tail -n +4)
        if [ -n "$FOLDERS" ]; then
            echo "$FOLDERS" | xargs rm -rf
        fi
    fi
}

if [ "$1" = "install" ]; then
    install_updater
else
    update_and_load
fi
