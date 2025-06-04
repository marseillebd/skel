#!/bin/bash
set -e
shopt -s globstar

version=0.1.0

skeldir="${XDG_CONFIG_HOME:-$HOME/.config}/skel"


# TODO allow holes (specific holes, not all names must be the same) to be edited in vi
# TODO allow string literal defaults
# TODO allow simple envvar defaults


top_help() {
  echo "skel --- use template files/directories"
  echo "usage:"
  echo "  skel list [ <PACKAGE> ]             print list of available packages, or templates in a package"
  echo "  skel mk <PACKAGE> [ <TEMPLATE> ]    copy template file/directory (without edits)"
  echo "  skel read [options]                 prompt on cmdline to fill in skel holes in the current directory"
  echo "    -n | --dry-run                      do not edit files, only list remaining holes"
  echo "  skel [-h | --help | help]           show help text"
  echo "  skel [-V | --version]               show version number"
  echo "See the readme for more information about concepts and configuration:"
  echo "  https://github.com/marseillebd/skel/blob/master/README.md"
}

main() {
  case "$1" in
    -h|--help|help) top_help; exit 0 ;;
    -V|--version) echo "skel v$version"; exit 0 ;;
    mk) shift; skel_mk "$@" ;;
    read) shift; skel_read "$@" ;;
    list) shift; skel_list "$@" ;;
    *)
      echo >&2 "$0: unrecognized command '$1' (try '$0 -h' for help)"
      exit 1
  esac
}

fileFindRegex='.*@@@[A-Z0-9_]+\(=\$([^()])\|=\${[A-Z0-9_]+}\)?@@@.*'
fileGrepRegex='@@@[A-Z0-9_]\+\(=\$([^)]*)\|=\${[A-Z0-9_]\+}\)\?@@@'
sedRegex() {
  local hole="$1"
  echo "@@@${hole}\(=\$([^)]*)\|=\${[^}]*}\)\?@@@"
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
    0) find "$skeldir/" -maxdepth 1 -type d -printf '%P\n' | tail -n+2;;
    1) find "$skeldir/$1/" -maxdepth 1 -type d -printf '%P\n' | tail -n+2;;
    *) list_help >&2; exit 1 ;;
  esac
}

skel_read() {
  local prevars vars hole var cmd envvar answer
  local dryRun=0
  if [ "$1" = '-n' ]; then dryRun=1; shift; fi
  prevars="$(
    {
      find . -regex "$fileFindRegex" \
        | sed 's/.*\(@@@[A-Z0-9_]\+\(=\$([^)]*)\|=\${[^}]*}\)\?@@@\).*/\1/'
      grep 2>/dev/null -r -oh "$fileGrepRegex" .
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
        if [ -n "$(eval "echo \"\$_cmd_$var\"")" ]; then
          echo >&2 "WARNING: conflicting defaults for $var"
          echo >&2 "  was: $(eval "echo \"\$_cmd_$var\"")"
        fi
        if [ -z "$vars" ]; then vars="$var"; else vars="$vars $var"; fi
        eval "_cmd_$var='$(echo "$cmd" | sed "s/'/'\\\\''/g")'"
      ;;
      *"=\${"*'}')
        var="${hole%%=*}"
        envvar="$(echo "$hole" | sed -e 's/[^=]*=\${//' -e 's/}$//')"
        if [ -n "$(eval "echo \"\$_envvar_$var\"")" ]; then
          echo >&2 "WARNING: conflicting defaults for $var"
          echo >&2 "  was: $(eval "echo \"\$_envvar_$var\"")"
        fi
        if [ -z "$vars" ]; then vars="$var"; else vars="$vars $var"; fi
        eval "_envvar_$var=\"$envvar\""
      ;;
      *)
        if [ -z "$vars" ]; then vars="$hole"; else vars="$vars $hole"; fi
      ;;
    esac
  done < <(echo "$prevars")
  vars="$(echo "$vars" | tr ' ' $'\n' | sort -u | tr $'\n' ' ')"

  # on a dry run, just describe the variables we found
  if [ "$dryRun" = 1 ]; then
    for hole in $vars; do
      local out="$hole"
      cmd="$(eval "echo \"\$_cmd_$hole\"")"
      envvar="$(eval "echo \"\$_envvar_$hole\"")"
      if [ -n "$cmd" ]; then
        out+="=\$($cmd)"
      elif [ -n "$envvar" ]; then
        out+="=\${$envvar}"
      fi
      echo "$out"
    done
    return 0
  fi

  for hole in $vars; do
    cmd="$(eval "echo \"\$_cmd_$hole\"")"
    envvar="$(eval "echo \"\$_envvar_$hole\"")"
    if [ -n "$cmd" ]; then
      printf '%s [default: $(%s)]: ' "$hole" "$cmd"
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
    elif [ -n "$envvar" ]; then
      printf '%s [default: ${%s}]: ' "$hole" "$envvar"
      read -r answer
      case "$answer" in
        '')
          eval "answer=\"\${$envvar}\""
        ;;
      esac
      case "$answer" in
        '') continue ;;
        *) replace "$hole" "$answer" ;;
      esac
    else
      printf "%s [default: skip]: " "$hole"
      read -r answer
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
  find . -regex "$fileFindRegex" | tac | while IFS='' read -r file; do
    # we have to iterate bottom-up or a `mv` higher up the filesystem will invalidate a path to a `mv` lower down
    # `find -regex` matches against the whole path, not single crumbs, so we have to check the basename
    if basename "$file" | grep -q "$fileGrepRegex"; then
      newfile="$( echo "$file" | sed "s"$'\v'"$(sedRegex "$hole")"$'\v'"$value"$'\v'"g" )"
      if [ "$file" != "$newfile" ]; then
        mv -v "$file" "$newfile"
      fi
    fi
  done
  for file in ./**/*; do
    if [ -f "$file" ]; then
      sed -i "s"$'\v'"$(sedRegex "$hole")"$'\v'"$value"$'\v'"g" "$file"
    fi
  done
}

main "$@"
