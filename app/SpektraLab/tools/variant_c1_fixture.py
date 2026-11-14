#!/usr/bin/env python3
"""variant_c1_fixture.py -- a Capture One catalog of three real pictures, one of them with two variants (PRD-G §6.4).

    python3 tools/variant_c1_fixture.py <schema.sql> <out dir> <a.jpg> <b.jpg>

Writes `<out>/Variants.cocatalog/Variants.cocatalogdb` and `<out>/Photos/{A,B,C}.jpg` (copies, so a develop's writes
never reach the tree's pictures). The catalog is the SDK's own synthetic one (`SpektraLab_library/tests/tests.cpp`,
`FakeCatalog`), row for row, on the SDK's Capture One 16.8 schema (`tests/fixtures/capture_one_16_8_schema.sql`,
passed in: the SDK's repository is read, never copied here), with three differences: the files are real pictures
the app can make frames of, there are three images, and image A has two variants -- VAR-A1 (index 127, no stars)
and VAR-A2 (index 255, four stars), as Capture One numbers a second variant.

Only the system's sqlite3 module; nothing of the person's is read or written.
"""
import os
import shutil
import sqlite3
import sys


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip().splitlines()[2].strip())
        return 2
    schema, out, a, b = sys.argv[1:]
    photos = os.path.join(out, "Photos")
    package = os.path.join(out, "Variants.cocatalog")
    os.makedirs(photos, exist_ok=True)
    os.makedirs(package, exist_ok=True)
    for src, name in ((a, "A.jpg"), (b, "B.jpg"), (a, "C.jpg")):
        shutil.copyfile(src, os.path.join(photos, name))
    db = os.path.join(package, "Variants.cocatalogdb")
    if os.path.exists(db):
        os.remove(db)
    c = sqlite3.connect(db)
    with open(schema, encoding="utf-8") as f:
        c.executescript(f.read())
    x = c.execute
    x("INSERT INTO ZVERSIONINFO VALUES (32, 1, '16.8.6.25 Pro Mac', '9.0.0 Mac', 160800, '16.8.6.25 Pro Mac', 160800)")
    x("INSERT INTO ZDOCUMENTCONTENT (Z_ENT, Z_PK, ZDATECREATED, ZDOCUMENTTYPE, ZDOCUMENTUUID, ZROOTCOLLECTION)"
      " VALUES (34, 1, 1729735821, 1, '22222222-3333-4444-5555-666666666666', 1)")
    ph = os.path.realpath(photos)
    x("INSERT INTO ZPATHLOCATION (Z_ENT, Z_PK, ZMACROOT, ZRELATIVEPATH, ZISRELATIVE, ZVOLUME) VALUES"
      " (38, 3, '/', ?, 0, '/'), (38, 6, '/', ?, 0, '/')", (ph[1:], os.path.dirname(ph)[1:]))
    x("INSERT INTO ZIMAGE (Z_ENT, Z_PK, ZIMAGEUUID, ZIMAGEFILENAME, ZDISPLAYNAME, ZIMAGELOCATION, ZISINSIDECATALOG,"
      " ZISTRASHED, ZIMAGECLASSIFICATION, ZWIDTH, ZHEIGHT, ZEXP_DATE, ZIMPORTDATE, ZCAMERA_MAKE, ZCAMERA_MODEL, ZISO) VALUES"
      " (12, 1, 'IMG-A', 'A.jpg', 'A', 3, 0, 0, 19, 4000, 3000, 1704757144.25, 1729841315.9, NULL, NULL, NULL),"
      " (12, 2, 'IMG-B', 'B.jpg', 'B', 3, 0, 0, 19, 4000, 3000, 1704757148, 1729841315.9, NULL, NULL, NULL),"
      " (12, 3, 'IMG-C', 'C.jpg', 'C', 3, 0, 0, 19, 4000, 3000, 1704757200, 1729841316, NULL, NULL, NULL)")
    variants = [(1, 1, 127, 101, "VAR-A1", 0, 0), (2, 1, 255, 102, "VAR-A2", 4, 0),
                (3, 2, 127, 103, "VAR-B1", 3, 2), (4, 3, 127, 104, "VAR-C1", 0, 0)]
    for pk, image, index, layer, uuid, rating, colour in variants:
        x("INSERT INTO ZVARIANT (Z_ENT, Z_PK, ZINDEX, ZVARIANTUUID, ZIMAGE, ZCOMBINEDSETTINGS, ZISMODIFIED)"
          " VALUES (15, ?, ?, ?, ?, ?, 0)", (pk, index, uuid, image, layer))
        x("INSERT INTO ZVARIANTLAYER (Z_ENT, Z_PK, ZVARIANT, ZROTATION, ZFLIP) VALUES (20, ?, ?, 0.0, 0)", (layer, pk))
        x("INSERT INTO ZVARIANTMETADATA (Z_ENT, Z_PK, ZLAYER, ZBASIC_RATING, ZCOLOR_TAG_INDEX, ZCONTACT_CREATOR)"
          " VALUES (13, ?, ?, ?, ?, 'A Photographer')", (layer, layer, rating, colour))
    x("INSERT INTO ZCOLLECTION (Z_ENT, Z_PK, ZUUID, ZNAME, ZPARENT, ZCOLLECTIONINDEX, ZFOLDERLOCATION, ZALLIMAGESCOLLECTION,"
      " ZLASTIMPORTSCOLLECTION, ZLASTCAPTURESCOLLECTION, ZTRASHCOLLECTION) VALUES"
      " (7, 1, 'COL-ROOT', 'root', NULL, 0, NULL, 2, 3, 4, 5),"
      " (40, 2, 'COL-ALL', 'All Images', 1, 1, NULL, NULL, NULL, NULL, NULL),"
      " (8, 3, 'COL-RI', 'Recent Imports', 1, 2, NULL, NULL, NULL, NULL, NULL),"
      " (8, 4, 'COL-RC', 'Recent Captures', 1, 3, NULL, NULL, NULL, NULL, NULL),"
      " (11, 5, 'COL-TRASH', 'Trash', 1, 4, NULL, NULL, NULL, NULL, NULL),"
      " (39, 6, 'COL-INCAT', 'Catalog', 1, 5, NULL, NULL, NULL, NULL, NULL),"
      " (2, 7, 'COL-IMPORT', 'Import', 3, 1, NULL, NULL, NULL, NULL, NULL),"
      " (36, 20, 'COL-F-ROOT', NULL, NULL, NULL, 6, NULL, NULL, NULL, NULL),"
      " (36, 21, 'COL-F-PHOTOS', NULL, 20, NULL, 3, NULL, NULL, NULL, NULL)")
    x("UPDATE ZCOLLECTION SET ZDATECREATED = 1791120697 WHERE Z_PK = 7")
    x("INSERT INTO ZIMAGEINCOLLECTION (Z_ENT, Z_PK, ZCOLLECTION, ZIMAGE) VALUES"
      " (47, 1, 7, 1), (47, 2, 7, 2), (47, 3, 7, 3), (47, 6, 21, 1), (47, 7, 21, 2), (47, 8, 21, 3)")
    c.commit()
    c.close()
    print(os.path.join(package))
    return 0


if __name__ == "__main__":
    sys.exit(main())
