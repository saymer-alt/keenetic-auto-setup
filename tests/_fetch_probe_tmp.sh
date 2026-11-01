fetch() {
  local code
  code=$(curl -sSL --max-time 20 -o "$2" -w '%{http_code}' "$1" 2>/dev/null) || return 1
  echo "FETCH-CURL-EXIT:0 CODE:[$code]" >&2
  if [ "$code" = "200" ]; then return 0; fi
  if [ "$code" = "404" ]; then return 4; fi
  return 1
}
fetch "$1" /dev/null
echo "fetch rc=$?"
