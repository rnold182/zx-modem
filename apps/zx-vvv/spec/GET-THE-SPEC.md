# The 8TML spec package goes here

The 8TML 1 specification package (spec text, example pages and the Python
reference tool) is by the 8TML author and isn't redistributed in this
repository: its license isn't settled yet.

- Read the spec online: https://t8wn.com/8tml/
- If you have the package (`8tml-v1.0-specs`, a zip), unzip it into this
  folder, so that `spec/8tml-1.md` and `tools/8tml` end up here. Everything
  in this folder except this file is ignored by git.

zx-vvv's tests use the reference tool from here as the layout oracle:

```
python apps/zx-vvv/spec/tools/8tml render -m zx --plain --links page.8tml
```
