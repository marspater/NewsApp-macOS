import urllib.request
import json
import os

repo = "marspater/NewsApp-macOS"

try:
    url = f"https://api.github.com/repos/{repo}/pulls?state=open"
    req = urllib.request.Request(url)
    if "GITHUB_TOKEN" in os.environ:
        req.add_header("Authorization", f"Bearer {os.environ['GITHUB_TOKEN']}")

    with urllib.request.urlopen(req) as response:
        pulls = json.loads(response.read().decode())
        for pr in pulls:
            if "⚡ Bolt: Pre-compile NSRegularExpression" in pr.get("title", ""):
                print(f"Found PR Branch: {pr['head']['ref']}")
                break
        else:
             print("Branch not found in open PRs.")
except Exception as e:
    print(f"Error fetching PRs: {e}")
