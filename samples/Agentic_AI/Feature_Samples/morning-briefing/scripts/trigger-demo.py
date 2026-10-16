"""
Run this in a terminal during the screen recording.
It calls the morning briefing endpoint and pretty-prints the response.
"""
import urllib.request, json, sys

URL = "http://localhost:9095/api/morning-briefing"

print("=" * 60)
print(" GET", URL)
print("=" * 60)
print()

try:
    r = urllib.request.urlopen(URL, timeout=90)
    body = r.read().decode()
    print(f"HTTP {r.status} OK\n")
    # Try to parse as JSON for pretty display
    try:
        data = json.loads(body)
        briefing = data.get("briefing", body)
    except Exception:
        briefing = body
    print(briefing)
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}: {e.read().decode()}")
    sys.exit(1)
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)

print()
print("=" * 60)
print(" Powered by TIBCO Flogo 2.26.2 + OpenAI gpt-4o")
print("=" * 60)
