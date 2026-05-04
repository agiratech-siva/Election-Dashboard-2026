import os
import re
import json
import time
from datetime import datetime
from urllib.request import Request, urlopen
from http.server import HTTPServer, BaseHTTPRequestHandler

BASE_URL = 'https://results.eci.gov.in/ResultAcGenMay2026'
REFERER = f'{BASE_URL}/partywiseresult-S22.htm'
DASH_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dashboard.html')
CACHE_TTL = 45

cache = None
cache_time = 0

def get_headers():
    return {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'none',
        'Sec-Fetch-User': '?1',
        'Upgrade-Insecure-Requests': '1',
        'Referer': REFERER
    }

def fetch_url(url):
    req = Request(url, headers=get_headers())
    with urlopen(req) as response:
        return response.read().decode('utf-8')

def parse_party_totals(html):
    flat = re.sub(r'\s+', ' ', html)
    pattern = r'<tr class="tr">\s*<td style="text-align:left">([^<]+)</td>\s*<td style="text-align:right">\s*(?:<a [^>]+>)?([0-9]+)(?:</a>)?\s*</td>\s*<td style="text-align:right">\s*(?:<a [^>]+>)?([0-9]+)(?:</a>)?\s*</td>\s*<td style="text-align:right">\s*(?:<a [^>]+>)?([0-9]+)(?:</a>)?\s*</td>'
    matches = re.finditer(pattern, flat)
    lst = []
    for m in matches:
        full = m.group(1).strip()
        code = ''
        code_match = re.search(r' - ([A-Za-z0-9()]+)\s*$', full)
        if code_match:
            code = code_match.group(1)
        
        name = re.sub(r' - [A-Za-z0-9()]+\s*$', '', full).strip()
        lst.append({
            'name': name,
            'code': code,
            'won': int(m.group(2)),
            'leading': int(m.group(3)),
            'total': int(m.group(4))
        })
    return lst

def parse_last_updated(html):
    m = re.search(r'Last Updated at\s*<span>([^<]+)</span>', html)
    return m.group(1).strip() if m else ''

def parse_constituencies(html):
    flat = re.sub(r'\s+', ' ', html)
    pattern = r"<tr[^>]*>\s*<td[^>]*align=['\"]left['\"][^>]*>([^<]+)</td>\s*<td[^>]*align=['\"]right['\"][^>]*>(\d+)</td>\s*(.*?)\s*<td[^>]*align=['\"]right['\"][^>]*>(\d+)</td>\s*<td[^>]*align=['\"]right['\"][^>]*>(\d+/\d+)</td>\s*<td[^>]*align=['\"]left['\"][^>]*>([^<]+)</td>\s*</tr>"
    matches = re.finditer(pattern, flat)
    out = []
    for m in matches:
        mid = m.group(3)
        lc = re.search(r"<td[^>]*align=['\"]left['\"][^>]*>([^<]+)</td>", mid)
        lp = re.search(r"<table[^>]*>.*?<td[^>]*align=['\"]left['\"][^>]*>([^<]+)</td>", mid)
        tc = re.search(r"<td[^>]*align=['\"]left['\"][^>]*>([^<]+)</td>\s*<td>\s*<table[^>]*>.*?<td[^>]*align=['\"]left['\"][^>]*>([^<]+)</td>", mid)
        
        out.append({
            'name': m.group(1).strip(),
            'no': int(m.group(2)),
            'leadCand': lc.group(1).strip() if lc else '',
            'leadParty': lp.group(1).strip() if lp else '',
            'trailCand': tc.group(1).strip() if tc else '',
            'trailParty': tc.group(2).strip() if tc else '',
            'margin': int(m.group(4)),
            'round': m.group(5),
            'status': m.group(6).strip()
        })
    return out

def parse_vote_share(html):
    pi_match = re.search(r"// Pi Charts.*?var xValues = \[(.*?)\];.*?var yValues = \[(.*?)\];", html, re.DOTALL)
    if not pi_match:
        return []
    
    x_raw = pi_match.group(1)
    y_raw = pi_match.group(2)
    
    labels = [m.group(1) for m in re.finditer(r"'([^']+)'", x_raw)]
    vals = [int(v.strip()) for v in y_raw.split(',') if re.match(r'^\s*\d+\s*$', v)]
    
    share = []
    for i, lbl in enumerate(labels):
        code = lbl
        pct = None
        m = re.match(r'^(.+?)\{([0-9.]+)%\}$', lbl)
        if m:
            code = m.group(1)
            pct = float(m.group(2))
        
        share.append({
            'code': code,
            'percent': pct,
            'votes': vals[i] if i < len(vals) else 0
        })
    return share

def fetch_all():
    print('[fetch] starting...')
    start_ms = time.time()
    
    party_html = fetch_url(f"{BASE_URL}/partywiseresult-S22.htm")
    totals = parse_party_totals(party_html)
    last_upd = parse_last_updated(party_html)
    vote_share = parse_vote_share(party_html)
    
    all_html = ''
    for i in range(1, 13):
        time.sleep(0.25)
        try:
            all_html += fetch_url(f"{BASE_URL}/statewiseS22{i}.htm")
        except Exception as e:
            print(f"[fetch] page {i} error: {e}")
            
    constits = parse_constituencies(all_html)
    
    elapsed = int((time.time() - start_ms) * 1000)
    print(f"[fetch] done in {elapsed} ms — parties={len(totals)} constits={len(constits)} lastUpd={last_upd}")
    
    return {
        'state': 'Tamil Nadu',
        'election': 'General Election to Assembly Constituencies, May 2026',
        'totalSeats': 234,
        'majority': 118,
        'lastUpdatedECI': last_upd,
        'fetchedAt': datetime.now().isoformat(),
        'parties': totals,
        'constituencies': constits,
        'voteShare': vote_share
    }

def get_data(force=False):
    global cache, cache_time
    age = time.time() - cache_time
    if force or cache is None or age > CACHE_TTL:
        try:
            cache = fetch_all()
            cache_time = time.time()
        except Exception as e:
            print(f"[fetch] FAILED: {e}")
            if cache is None:
                raise e
    return cache

class RequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] {self.command} {self.path}")
            
            if self.path in ('/', '/dashboard.html'):
                self.send_response(200)
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                with open(DASH_FILE, 'rb') as f:
                    self.wfile.write(f.read())
                    
            elif self.path in ('/api/data', '/api/refresh'):
                force = (self.path == '/api/refresh')
                data = get_data(force)
                age = int(time.time() - cache_time)
                
                self.send_response(200)
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Cache-Age', str(age))
                self.send_header('Content-type', 'application/json; charset=utf-8')
                self.end_headers()
                
                body = json.dumps(data, separators=(',', ':')).encode('utf-8')
                self.wfile.write(body)
                
            else:
                self.send_response(404)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"error":"not found"}')
                
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
            # Client (like ngrok) disconnected before we finished sending the response
            pass
        except Exception as e:
            try:
                self.send_response(500)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                err = json.dumps({'error': str(e)}).encode('utf-8')
                self.wfile.write(err)
            except Exception:
                pass
            print(f"[err] {e}")

    def log_message(self, format, *args):
        # Override to suppress default HTTP server logging since we do it manually
        pass

def run(server_class=HTTPServer, handler_class=RequestHandler, port=8081):
    server_address = ('', port)
    httpd = server_class(server_address, handler_class)
    print("")
    print("  ╔════════════════════════════════════════════════╗")
    print("  ║  ECI Verdict 2026 — Tamil Nadu live dashboard  ║")
    print(f"  ║  Open locally: http://localhost:{port}/          ║")
    print("  ║  Network access enabled (see IP from before)   ║")
    print("  ║  Press Ctrl+C to stop                          ║")
    print("  ╚════════════════════════════════════════════════╝")
    print("")
    
    try:
        get_data()
    except Exception as e:
        print("Warm cache failed (will retry on first request).")
        
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    httpd.server_close()

if __name__ == '__main__':
    port = int(os.environ.get('PORT', '8081'))
    run(port=port)
