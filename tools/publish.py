"""Publish module/ into the game's module folder under the version in definition.yml.

The UCP GUI notices a new version on F5 and moves the pin with its apply button, so a build
is always *copied* to a new folder and older folders are left alone until they are safe to
remove. `ucp-config.yml` is never written here - the apply button owns it - but it is read,
because the version it pins must still exist on disk. Deleting a pinned folder is what makes
the GUI refuse the whole config with MISSING_DEPENDENCIES.

    python tools/publish.py            # copy module/ to building-overlays-<version>
    python tools/publish.py --bump     # raise the last version slot first
    python tools/publish.py --keep     # publish and clear nothing
"""
import os, re, shutil, sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE = os.path.join(HERE, 'module')
GAME = r'H:\steam\steamapps\common\Stronghold Crusader Extreme UCP3 new'
MODULES = os.path.join(GAME, 'ucp', 'modules')
CONFIG = os.path.join(GAME, 'ucp-config.yml')
NAME = 'building-overlays'


def version(text):
    return tuple(int(part) for part in text.split('.'))


def read_version():
    path = os.path.join(MODULE, 'definition.yml')
    with open(path, encoding='utf-8') as f:
        text = f.read()
    return re.search(r'^version:\s*(\S+)', text, re.M).group(1), path, text


def bump():
    current, path, text = read_version()
    parts = current.split('.')
    parts[-1] = str(int(parts[-1]) + 1)
    new = '.'.join(parts)
    text = re.sub(r'^version:\s*\S+', 'version: ' + new, text, count=1, flags=re.M)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print('%s -> %s' % (current, new))
    return new


def pinned():
    """Every version of this module the GUI's config asks for. Read only."""
    if not os.path.isfile(CONFIG):
        return set()
    with open(CONFIG, encoding='utf-8', errors='replace') as f:
        text = f.read()
    found = re.findall(r'-\s*extension:\s*%s\s*\n\s*version:\s*(\S+)' % re.escape(NAME), text)
    return {version(v) for v in found}


def installed():
    found = []
    for entry in os.listdir(MODULES):
        if entry.startswith(NAME + '-') and os.path.isdir(os.path.join(MODULES, entry)):
            tail = entry[len(NAME) + 1:]
            if re.fullmatch(r'\d+(\.\d+)*', tail):
                found.append((version(tail), entry))
    return sorted(found)


def main():
    current = bump() if '--bump' in sys.argv else read_version()[0]
    target = os.path.join(MODULES, '%s-%s' % (NAME, current))
    if os.path.isdir(target):
        shutil.rmtree(target)
    shutil.copytree(MODULE, target)
    print('published', os.path.basename(target))

    held = pinned()
    if held:
        print('the config pins', ', '.join('%s' % '.'.join(map(str, v)) for v in sorted(held)))
    if '--keep' in sys.argv:
        print('installed:', ', '.join(entry for _, entry in installed()))
        return

    # What stays: this build, whatever the config still pins - deleting that is what gives
    # the GUI MISSING_DEPENDENCIES and stops it loading at all - and the newest build
    # besides this one, so there is always something to fall back to. Everything else goes,
    # because the GUI lists every folder it finds.
    keep = {version(current)} | held
    others = [v for v, _ in installed() if v != version(current)]
    if others:
        keep.add(max(others))
    for v, entry in installed():
        if v not in keep:
            shutil.rmtree(os.path.join(MODULES, entry))
            print('cleared', entry)
    print('installed:', ', '.join(entry for _, entry in installed()))


if __name__ == '__main__':
    main()
