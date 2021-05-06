#!/bin/bash
set -e
shopt -s globstar

skeldir="${XDG_CONFIG_HOME:-$HOME/.config}/skel"


# TODO allow holes (specific holes, not all names must be the same) to be edited in vi
# TODO list hole names (and defaults?) without editing
# TODO allow string literal defaults
# TODO allow simple envvar defaults


top_help() {
  echo "skel --- use template files/directories"
  echo "usage:"
  echo "  skel mk <PACKAGE> [ <TEMPLATE> ]    copy template file/directory (without edits)"
  echo "  skel read [ <HOLES...> ]            prompt on cmdline to fill in skel holes"
}

main() {
  case "$1" in
    -h|--help) top_help; exit 0 ;;
    -V|--version) echo "skel v0.0.0"; exit 0 ;;
    mk) shift; skel_mk "$@" ;;
    read) shift; skel_read "$@" ;;
    list) shift; skel_list "$@" ;;
    *) top_help >&2; exit 1
  esac
}

skel_mk() {
  local pkg tmpl
  case "$#" in
    2) pkg="$1"; tmpl="$2" ;;
    1) pkg="$1"; tmpl=default ;;
    *) mk_help >&2; exit 1 ;;
  esac
  if [ -d "$skeldir/$pkg/$tmpl" ]; then
    cp -rvi "$skeldir/$pkg/$tmpl"/* .
  elif [ -f "$skeldir/$pkg/default" ]; then
    cp -vi "$skeldir/$pkg/$tmpl" .
  else
    echo >&2 "no default skeleton for $pkg ($skeldir/$pkg/default)"
    exit 1
  fi
}

skel_list() {
  case "$#" in
    0) find "$skeldir" -maxdepth 1 -type d -printf '%P\n' | tail -n+2;;
    1) find "$skeldir/$1" -printf '%P\n' | tail -n+2;;
    *) list_help >&2; exit 1 ;;
  esac
}

skel_read() {
  local prevars vars hole var cmd answer
  prevars="$(
    {
      find . -regex '.*@@@[A-Z0-9_]+\(=\$([^()])\)?@@@.*' | sed 's/.*\(@@@[A-Z0-9_]\+\(=\$([^)]*)\)\?@@@\).*/\1/'
      grep 2>/dev/null -r -oh '@@@[A-Z0-9_]\+\(=\$([^)]*)\)\?@@@' .
    } | sort -u
  )"
  vars=''
  while IFS='' read -r hole; do
    hole="${hole#@@@}"
    hole="${hole%@@@}"
    case "$hole" in
      *"=\$("*')')
        var="${hole%%=*}"
        cmd="$(echo "$hole" | sed -e 's/[^=]*=\$(//' -e 's/)$//')"
        if [ -n "$(eval "echo \"\$default_$var\"")" ]; then
          echo >&2 "WARNING: conflicting defaults for $var"
          echo >&2 "  was: $(eval "echo \"\$default_$var\"")"
        fi
        if [ -z "$vars" ]; then vars="$var"; else vars="$vars $var"; fi
        eval "default_$var='$(echo "$cmd" | sed "s/'/'\\\\''/g")'"
      ;;
      *)
        if [ -z "$vars" ]; then vars="$hole"; else vars="$vars $hole"; fi
      ;;
    esac
  done < <(echo "$prevars")
  vars="$(echo "$vars" | tr ' ' $'\n' | sort -u | tr $'\n' ' ')"

  # go through vars that don't have defaults first
  for hole in $vars; do
    cmd="$(eval "echo \"\$default_$hole\"")"
    if [ -z "$cmd" ]; then
      printf "%s [default: skip]: " "$hole"
      read -r answer
      case "$answer" in
        '') continue ;;
        *) replace "$hole" "$answer" ;;
      esac
    fi
  done
  # then go through those that have defaults
  for hole in $vars; do
    cmd="$(eval "echo \"\$default_$hole\"")"
    if [ -n "$cmd" ]; then
      printf "%s [default: \$(%s)]: " "$hole" "$cmd"
      read -r answer
      case "$answer" in
        '')
          eval "answer=\"\$($cmd)\""
        ;;
      esac
      case "$answer" in
        '') continue ;;
        *) replace "$hole" "$answer" ;;
      esac
    fi
  done
}

replace() {
  local hole value
  hole="$1"
  value="$2"
  local file newfile
  find . -regex '.*@@@[A-Z0-9_]+\(=\$([^()])\)?@@@.*' | while IFS='' read -r file; do
    newfile="$(echo "$file" | sed "s/@@@${hole}\(=\$([^)]*)\)\?@@@/$value/g")"
    if [ "$file" != "$newfile" ]; then
      mv -v "$file" "$newfile"
    fi
  done
  for file in ./**/*; do
    if [ -f "$file" ]; then
      sed -i "s"$'\v'"@@@${hole}\(=\$([^)]*)\)\?@@@"$'\v'"$value"$'\v'"g" "$file"
    fi
  done
}

main "$@"
