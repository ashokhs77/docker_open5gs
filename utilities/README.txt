OFFLINE BUNDLE SCRIPTS - docker_open5gs
=======================================

Files
-----
export_images.sh   Run on the ONLINE / source machine. Creates an offline bundle.
import_images.sh   Run on the OFFLINE / target machine. Applies the bundle.

1. EXPORT  (export_images.sh)
-----------------------------
Run from the directory that CONTAINS the docker_open5gs/ folder:

    chmod +x export_images.sh
    ./export_images.sh

Menu:
    1) CODE ONLY
    2) IMAGES ONLY
    3) CODE + IMAGES

Questions asked (only for options 1 and 3, since they include code):
    Include .env in the bundle?               (y/N)
    Include dispatcher.list files?            (y/N)
  Pressing Enter means "no" for both.

Image questions (only for options 2 and 3):
    a) ALL     every Docker image on this machine (not only this project's)
    b) SELECT  shows a numbered list; type numbers, e.g.  1 3 5
  Anything other than "a" goes to SELECT.

Result:
    offline_bundle_<YYYYMMDD_HHMM>_<code_only|images_only|code_images>.tar.gz
  created in the current directory. Copy this file to the offline machine.

When to answer "y":
  .env              First install on a new machine (it has no .env yet).
                    A "y" OVERWRITES the target's .env with the source one.
  dispatcher.list   Only if the target should use the source's copy.
                    A "y" OVERWRITES the target's dispatcher.list files.
  For normal updates answer "n" to both, so the target keeps its own files.


2. IMPORT  (import_images.sh)
-----------------------------
1. Put the bundle and import_images.sh in the folder where docker_open5gs/
   should live (the folder is created if it does not exist).
2. Keep only ONE offline_bundle_*.tar.gz there. If several exist, the newest
   (by file name) is used.
3. Run:

       chmod +x import_images.sh
       ./import_images.sh

What it does:
    1. Extracts the bundle into a temporary tmp_import_* folder.
    2. If the bundle has code: copies it over docker_open5gs/ (rsync, or tar
       if rsync is missing). Only files that are in the bundle are touched;
       everything else in docker_open5gs/ is left as it is.
    3. If the bundle has images: runs  docker load.
    4. Deletes the temporary folder.
    5. Runs  docker compose -f 4g-volte-deploy.yaml down  inside docker_open5gs/
       (volumes are kept, so databases survive).
    6. Runs  docker image prune -f  (removes unused untagged images only).

The bundle file itself is NOT deleted. Remove it yourself when finished.

Then start the stack:

    cd docker_open5gs
    docker compose -f 4g-volte-deploy.yaml up -d
