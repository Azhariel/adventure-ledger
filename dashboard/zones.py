"""Classic zone maps for the Live tab: uiMapID (what the combat log and MuddyBoots use) -> Wowhead zone id (area id),
and where the map's coordinate square sits inside Wowhead's image.

Wowhead's classic map images (wow.zamimg.com/images/wow/classic/maps/enus/original/<zone>.jpg) are 1022 x 668: the
game's 1002 x 668 map with a 10 px frame on the left and right. Map coordinate x in [0, 1] is image pixel
10 + x * 1002; y is y * 668. Checked on 8 Nov 2026 by drawing MuddyBoots' Silverpine trail over the image: the points
follow the roads.
"""
IMAGE_URL = "https://wow.zamimg.com/images/wow/classic/maps/enus/original/%d.jpg"
IMAGE = {"width": 1022, "height": 668, "left": 10, "mapWidth": 1002, "mapHeight": 668}

# uiMapID -> (Wowhead zone id, name). Names only make the table easy to check.
ZONES = {
    1411: (14, "Durotar"), 1412: (215, "Mulgore"), 1413: (17, "The Barrens"), 1416: (36, "Alterac Mountains"),
    1417: (45, "Arathi Highlands"), 1418: (3, "Badlands"), 1419: (4, "Blasted Lands"), 1420: (85, "Tirisfal Glades"),
    1421: (130, "Silverpine Forest"), 1422: (28, "Western Plaguelands"), 1423: (139, "Eastern Plaguelands"),
    1424: (267, "Hillsbrad Foothills"), 1425: (47, "The Hinterlands"), 1426: (1, "Dun Morogh"),
    1427: (51, "Searing Gorge"), 1428: (46, "Burning Steppes"), 1429: (12, "Elwynn Forest"),
    1430: (41, "Deadwind Pass"), 1431: (10, "Duskwood"), 1432: (38, "Loch Modan"), 1433: (44, "Redridge Mountains"),
    1434: (33, "Stranglethorn Vale"), 1435: (8, "Swamp of Sorrows"), 1436: (40, "Westfall"), 1437: (11, "Wetlands"),
    1438: (141, "Teldrassil"), 1439: (148, "Darkshore"), 1440: (331, "Ashenvale"), 1441: (400, "Thousand Needles"),
    1442: (406, "Stonetalon Mountains"), 1443: (405, "Desolace"), 1444: (357, "Feralas"),
    1445: (15, "Dustwallow Marsh"), 1446: (440, "Tanaris"), 1447: (16, "Azshara"), 1448: (361, "Felwood"),
    1449: (490, "Un'Goro Crater"), 1450: (493, "Moonglade"), 1451: (1377, "Silithus"), 1452: (618, "Winterspring"),
    1453: (1519, "Stormwind City"), 1454: (1637, "Orgrimmar"), 1455: (1537, "Ironforge"),
    1456: (1638, "Thunder Bluff"), 1457: (1657, "Darnassus"), 1458: (1497, "Undercity"),
}
