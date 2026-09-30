import subprocess
import urllib.request
import json
import zipfile
import io

p = subprocess.Popen(['git', 'credential', 'fill'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
out, _ = p.communicate('protocol=https\nhost=github.com\n\n')
token = ''
for line in out.splitlines():
    if line.startswith('password='):
        token = line.split('=', 1)[1]
        break

headers = {
    'Authorization': f'Bearer {token}',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'Python'
}

run_id = '36671573531'
jobs_req = urllib.request.Request(f'https://api.github.com/repos/n1cknam3l3ss/IsaacExternalItemDescriptionsiOS/actions/runs/{run_id}/jobs', headers=headers)
with urllib.request.urlopen(jobs_req) as resp:
    jobs = json.loads(resp.read().decode('utf-8'))

job_id = jobs['jobs'][0]['id']
print(f"Fetching logs for job {job_id}...")

class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is not None and 'Authorization' in new_req.headers:
            del new_req.headers['Authorization']
        return new_req

opener = urllib.request.build_opener(NoAuthRedirect)
log_req = urllib.request.Request(f'https://api.github.com/repos/n1cknam3l3ss/IsaacExternalItemDescriptionsiOS/actions/jobs/{job_id}/logs', headers=headers)
try:
    with opener.open(log_req) as resp:
        log_text = resp.read().decode('utf-8', errors='replace')
        lines = log_text.splitlines()
        print(f"Total log lines: {len(lines)}")
        error_lines = [line for line in lines if 'error:' in line or 'warning:' in line or 'BUILD FAILED' in line]
        for el in error_lines[-30:]:
            print(el)
        print("\nLast 50 lines of log:")
        for line in lines[-50:]:
            print(line)
except Exception as e:
    print("Error fetching logs:", e)
