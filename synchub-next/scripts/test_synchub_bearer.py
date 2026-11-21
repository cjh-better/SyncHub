"""Exercise synchub_server.check_gateway_token against a running gateway
without importing the whole server module (which expects /opt paths)."""
import ast, hashlib, json, os, sys, threading, time

src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
want = {"check_gateway_token", "check_basic_auth"}
body = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in want]
ns = {"os": os, "json": json, "time": time, "hashlib": hashlib, "threading": threading,
      "GATEWAY_URL": sys.argv[2], "_token_cache": {}, "_token_lock": threading.Lock(),
      "get_hub_credentials": lambda: None}
exec(compile(ast.Module(body=body, type_ignores=[]), "synchub", "exec"), ns)
good, bad = sys.argv[3], "shd_not_a_real_token"
assert ns["check_basic_auth"]("Bearer " + good) is True, "valid device token rejected"
assert ns["check_basic_auth"]("Bearer " + bad) is False, "invalid token accepted"
assert ns["check_basic_auth"](None) is False
print("synchub bearer auth OK")
