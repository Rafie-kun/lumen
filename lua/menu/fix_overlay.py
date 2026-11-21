#!/usr/bin/env python3
with open('09-overlay.js', 'r') as f:
    content = f.read()

old = '''          if (!config || !config.success) throw new Error((config && config.error) || "load failed");'''

new = '''          if (!config || !config.success) {
            slsBody.textContent = "";
            var err = document.createElement("div");
            err.className = "lumen-err";
            err.textContent = "Failed to load slsteam-moon config: " + (config && config.error ? config.error : "load failed");
            slsBody.appendChild(err);
            return;
          }'''

if old in content:
    content = content.replace(old, new, 1)
    with open('09-overlay.js', 'w') as f:
        f.write(content)
    print('Fix applied successfully')
else:
    print('Old pattern not found!')
    lines = content.split('\n')
    for i, line in enumerate(lines):
        if 'config.success' in line:
            print(f'{i+1}: {repr(line)}')

PYEOF