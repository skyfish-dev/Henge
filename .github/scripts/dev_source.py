# Writes a SideStore/AltStore source for a fork's own builds, from repo.json and the source it last wrote.
#
#   python3 -I dev_source.py <repo.json> <previous source or ""> <out> <version> <build> <ipa> <download URL> <notes>
#
# The newest build comes first; the last ten are kept. Add the source in SideStore once, and each build the
# workflow publishes shows there as an update.
import json, os, sys
from datetime import datetime, timezone

repo_json, previous, out, version, build, ipa, url, notes = sys.argv[1:9]
owner = os.environ.get("GITHUB_REPOSITORY_OWNER", "fork")
repository = os.environ.get("GITHUB_REPOSITORY", "")

source = json.load(open(repo_json, encoding="utf-8"))
source["name"] = f"Henge ({owner}'s builds)"
source["identifier"] = f"{source['identifier']}.{owner.lower()}"
source["subtitle"] = "Builds from this fork, before they're released."
source["description"] = f"Henge built from github.com/{repository} by GitHub Actions. Each build shows here as an update."
source["website"] = f"https://github.com/{repository}"
source["news"] = []

app = source["apps"][0]
app["developerName"] = f"Leviidev ({owner}'s build)"

kept = []
if previous and os.path.exists(previous):
    try:
        kept = [v for v in json.load(open(previous, encoding="utf-8"))["apps"][0]["versions"] if v.get("buildVersion") != build]
    except (ValueError, KeyError, IndexError):
        kept = []

app["versions"] = [{
    "version": version,
    "buildVersion": build,
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes,
    "downloadURL": url,
    "size": os.path.getsize(ipa),
    "minOSVersion": "17.0",
}] + kept[:9]
source["apps"] = [app]

with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"{out}: {version} ({build}), {len(app['versions'])} versions")
