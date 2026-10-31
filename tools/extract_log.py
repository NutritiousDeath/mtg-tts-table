"""Pull the table's game log and error list out of a TTS save file into text files.
usage: python3 extract_log.py <save.json> <out_dir>"""
import json, sys, os, re
save, out = sys.argv[1], sys.argv[2]
d = json.load(open(save, encoding='utf-8'))
tabs = {t.get('title'): t.get('body', '') for t in d.get('TabStates', {}).values()}
stamp = re.sub(r'[^0-9A-Za-z]+', '-', d.get('Date', 'save')).strip('-')
os.makedirs(out, exist_ok=True)
log = tabs.get('MTG Game Log', '')
errs = tabs.get('MTG Errors', '')
caught = [l for l in log.split('\n') if 'SCRIPT ERROR' in l]
p1 = os.path.join(out, f'{stamp} game log.txt')
p2 = os.path.join(out, f'{stamp} errors.txt')
open(p1, 'w', encoding='utf-8').write(log)
body = errs if errs.strip() else '\n'.join(caught)
open(p2, 'w', encoding='utf-8').write(body if body.strip() else 'No script errors recorded.\n')
hand = tabs.get('MTG By Hand', '')
p3 = os.path.join(out, f'{stamp} by hand.txt')
open(p3, 'w', encoding='utf-8').write(hand if hand.strip() else 'Nothing was left to do by hand.\n')
print(p1); print(p2); print(p3)
print('log lines', len(log.split('\n')), 'errors', len([l for l in body.split('\n') if l.strip()]), 'by hand', len([l for l in hand.split('\n') if l.strip()]))
