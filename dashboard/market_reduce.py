"""Reduce AH snapshots to per-item rows and estimate sales between two snapshots. Pure: no I/O."""
import math

# Lower bound of the time left in each bucket, in seconds.
TIME_LEFT_MIN = {"SHORT": 0, "MEDIUM": 1800, "LONG": 7200, "VERY_LONG": 43200}


def market_value(prices):
    """Mean of the cheapest units, ignoring an expensive tail. `prices`: one unit price per unit."""
    prices = sorted(prices)
    n = len(prices)
    take = max(1, math.ceil(0.15 * n))
    cap = max(take, math.floor(0.30 * n))
    while take < cap and prices[take] < 1.2 * prices[take - 1]:
        take += 1
    return round(sum(prices[:take]) / take)


def reduce(auctions, commodities):
    """{item_id: {"min", "market", "units", "listings"}} from both endpoints' lists."""
    prices = {}
    units = {}
    listings = {}
    for a in auctions:
        item = a["item"]["id"]
        qty = a["quantity"]
        if qty <= 0:
            continue   # nothing to sell; 0 would also divide by zero below and fail the whole house
        units[item] = units.get(item, 0) + qty
        listings[item] = listings.get(item, 0) + 1
        prices.setdefault(item, [])
        # Bid-only auctions have no buyout: they count as supply but have no price.
        if a.get("buyout"):
            prices[item].extend([a["buyout"] // qty] * qty)
    for c in commodities:
        item = c["item"]["id"]
        qty = c["quantity"]
        if qty <= 0:
            continue
        units[item] = units.get(item, 0) + qty
        listings[item] = listings.get(item, 0) + 1
        prices.setdefault(item, []).extend([c["unit_price"]] * qty)
    rows = {}
    for item, p in prices.items():
        if not p:
            continue  # only bid-only listings: nothing to price
        rows[item] = {"min": min(p), "market": market_value(p),
                      "units": units[item], "listings": listings[item]}
    return rows


def snapshot_ids(auctions, commodities):
    """{auction_id: (item_id, quantity, time_left)}, to compare with the next snapshot."""
    ids = {}
    for a in list(auctions) + list(commodities):
        ids[a["id"]] = (a["item"]["id"], a["quantity"], a.get("time_left"))
    return ids


def estimate_sold(prev, cur, gap_seconds):
    """{item_id: units} sold between two snapshots `gap_seconds` apart.

    A vanished auction only counts if it could not have expired in that gap."""
    sold = {}
    for aid, (item, qty, left) in prev.items():
        if aid in cur:
            drop = qty - cur[aid][1]
            if drop > 0:
                sold[item] = sold.get(item, 0) + drop
        elif TIME_LEFT_MIN.get(left, 0) >= gap_seconds:
            sold[item] = sold.get(item, 0) + qty
    return sold
