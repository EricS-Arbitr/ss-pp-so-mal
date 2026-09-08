#!/bin/bash
# Configure WordPress at www.voltgrid.com with the Voltgrid Power Co. corporate
# site content. Designed to run INSIDE the wordpress container via
# `docker compose exec`. Idempotent: re-running upserts pages, recreates the
# menu deterministically.
set -euo pipefail

# Locate the WordPress core install. Bitnami puts CORE files (wp-admin,
# wp-includes, wp-load.php) at /opt/bitnami/wordpress and only the *data*
# (wp-config.php + uploads) at /bitnami/wordpress, so checking for
# wp-config.php picks the wrong directory and wp-cli rejects it.
# Probe for wp-load.php instead — it only exists where WordPress core is.
WP_PATH=""
for p in /opt/bitnami/wordpress /bitnami/wordpress /var/www/html /var/www /app; do
  if [ -f "$p/wp-load.php" ]; then
    WP_PATH="$p"
    break
  fi
done
if [ -z "$WP_PATH" ]; then
  echo "ERROR: could not locate wp-load.php under any of:" >&2
  echo "  /opt/bitnami/wordpress  /bitnami/wordpress  /var/www/html  /var/www  /app" >&2
  echo "Run inside the container:  find / -maxdepth 5 -name wp-load.php 2>/dev/null" >&2
  exit 1
fi
echo "voltgrid_site: WordPress install located at $WP_PATH"
WP="wp --allow-root --path=$WP_PATH"

# --- Site identity ----------------------------------------------------------
$WP option update blogname        "Voltgrid Power Co." >/dev/null
$WP option update blogdescription "Reliable energy for Pennsylvania since 1923" >/dev/null
$WP option update timezone_string "America/New_York" >/dev/null
$WP option update default_comment_status "closed" >/dev/null

# --- Pages ------------------------------------------------------------------
# Each page's content lives at /tmp/voltgrid-content/<slug>.html. The Ansible
# task that wraps this script docker-cp's that directory into the container
# before invoking us.
upsert_page() {
  local slug="$1"
  local title="$2"
  local content
  content=$(cat "/tmp/voltgrid-content/${slug}.html")

  local id
  id=$($WP post list --post_type=page --name="$slug" --field=ID --format=ids 2>/dev/null || true)

  if [ -z "$id" ]; then
    $WP post create \
        --post_type=page \
        --post_status=publish \
        --post_name="$slug" \
        --post_title="$title" \
        --post_content="$content" >/dev/null
  else
    $WP post update "$id" \
        --post_title="$title" \
        --post_content="$content" >/dev/null
  fi
}

upsert_page home     "Home"
upsert_page about    "About Us"
upsert_page services "Services"
upsert_page coverage "Service Area"
upsert_page contact  "Contact"

# --- Static front page ------------------------------------------------------
home_id=$($WP post list --post_type=page --name=home --field=ID --format=ids)
$WP option update show_on_front page >/dev/null
$WP option update page_on_front "$home_id" >/dev/null

# --- Primary menu (rebuild deterministically) -------------------------------
menu_name="Primary"
if $WP menu list --fields=name --format=csv | tail -n +2 | grep -qx "$menu_name"; then
  $WP menu delete "$menu_name" >/dev/null
fi
menu_id=$($WP menu create "$menu_name" --porcelain)

for slug in home about services coverage contact; do
  page_id=$($WP post list --post_type=page --name="$slug" --field=ID --format=ids)
  $WP menu item add-post "$menu_id" "$page_id" >/dev/null
done

# External link to the billing portal (separate vhost on this same host).
$WP menu item add-custom "$menu_id" "Pay My Bill" "http://billing.voltgrid.com/" >/dev/null

# Try to bind the menu to whichever location the active theme exposes.
# Themes differ: some call it 'primary', some 'header', some 'main'.
for loc in primary header main top; do
  if $WP menu location list --format=csv | tail -n +2 | cut -d, -f1 | grep -qx "$loc"; then
    $WP menu location assign "$menu_id" "$loc" >/dev/null
    break
  fi
done

# --- Custom CSS -------------------------------------------------------------
# Apply Voltgrid brand styling (palette, typography, hero/card/stat blocks).
# WP stores theme-scoped Additional-CSS as a `custom_css` post whose post_name
# is the stylesheet (theme) slug. Upsert that post.
theme_slug=$($WP option get stylesheet)
css_content=$(cat /tmp/voltgrid-content/custom.css)
css_id=$($WP post list --post_type=custom_css --post_status=publish \
            --name="$theme_slug" --field=ID --format=ids 2>/dev/null || true)
if [ -z "$css_id" ]; then
  $WP post create \
      --post_type=custom_css \
      --post_status=publish \
      --post_name="$theme_slug" \
      --post_title="$theme_slug" \
      --post_content="$css_content" >/dev/null
else
  $WP post update "$css_id" --post_content="$css_content" >/dev/null
fi

# --- Tidy up ----------------------------------------------------------------
# Trash the auto-created "Hello world!" post and "Sample Page" so the site
# looks like a corporate site, not a fresh WordPress install.
for slug in hello-world sample-page; do
  pid=$($WP post list --post_status=publish --name="$slug" --field=ID --format=ids 2>/dev/null || true)
  if [ -n "$pid" ]; then
    $WP post delete "$pid" --force >/dev/null
  fi
done

echo "voltgrid_site: WordPress content provisioned."
