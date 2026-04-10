"""UseTrack MCP Server — expose activity data to LLMs via MCP protocol."""

from contextlib import asynccontextmanager

from fastmcp import FastMCP

from usetrack.db import DEFAULT_DB_PATH, UseTrackDB

# Global DB instance, initialized on server startup
_db: UseTrackDB | None = None


@asynccontextmanager
async def lifespan(server: FastMCP):
    """Initialize DB connection on startup, close on shutdown."""
    global _db
    _db = UseTrackDB(db_path=DEFAULT_DB_PATH)
    await _db.connect()
    yield
    await _db.close()


mcp = FastMCP("usetrack", lifespan=lifespan)


def _get_db() -> UseTrackDB:
    assert _db is not None, "Database not initialized"
    return _db


@mcp.tool()
async def get_activity_summary(period: str = "today") -> dict:
    """Get activity summary for a time period.

    Args:
        period: Time period — "today", "yesterday", "this_week", "last_week",
                "this_month", "YYYY-MM-DD", or "YYYY-MM-DD:YYYY-MM-DD" for range.

    Returns:
        Summary with total_events, total_active_min, unique_apps, top_apps, categories.
    """
    return await _get_db().get_activity_summary(period)


@mcp.tool()
async def query_activities(
    start: str,
    end: str,
    app_filter: str | None = None,
    category_filter: str | None = None,
    limit: int = 100,
) -> list[dict]:
    """Query raw activity events within a time range.

    Args:
        start: Start datetime (ISO format, e.g. "2026-04-10T09:00:00").
        end: End datetime (ISO format).
        app_filter: Filter by app name (partial match).
        category_filter: Filter by category (deep_work/communication/browsing/entertainment).
        limit: Max number of results (default 100).

    Returns:
        List of activity events with id, ts, activity, app_name, window_title, duration_s, category.
    """
    return await _get_db().query_activities(start, end, app_filter, category_filter, limit)


@mcp.tool()
async def get_focus_metrics(date: str = "today") -> dict:
    """Get focus and attention metrics for a specific date.

    Args:
        date: Target date — "today", "yesterday", or "YYYY-MM-DD".

    Returns:
        Metrics: deep_work_min, context_switches, ping_pong_switches,
        total_active_min, productivity_ratio, energy_curve (hourly deep work ratio).
    """
    return await _get_db().get_focus_metrics(date)


@mcp.tool()
async def search_activity(keyword: str, limit: int = 50) -> list[dict]:
    """Full-text search across window titles using FTS5 index.

    Args:
        keyword: Search query (supports FTS5 syntax: AND, OR, NOT, "phrase").
        limit: Max results (default 50).

    Returns:
        Matching activity events sorted by most recent.
    """
    return await _get_db().search_activity(keyword, limit)


@mcp.tool()
async def get_output_metrics(period: str = "today") -> dict:
    """Get productive output metrics for a time period.

    Args:
        period: Time period (same formats as get_activity_summary).

    Returns:
        Metrics: obsidian_words, git_commits, git_lines_added, git_lines_removed,
        code_time_min (varies by what's tracked).
    """
    return await _get_db().get_output_metrics(period)


@mcp.tool()
async def get_trends(metric: str, days: int = 7) -> dict:
    """Get trend data for a metric over N days.

    Args:
        metric: Metric name — "deep_work", "context_switches", "active_time",
                or any output_metrics type (e.g. "git_commits", "obsidian_words").
        days: Number of days to look back (default 7).

    Returns:
        Daily data points: [{date, value}, ...].
    """
    return await _get_db().get_trends(metric, days)


@mcp.tool()
async def get_distraction_patterns(period: str = "today") -> dict:
    """Analyze distraction patterns for a time period.

    Args:
        period: Time period (same formats as get_activity_summary).

    Returns:
        Analysis: frequent_short_switches (apps switched away from quickly),
        distraction_time_min (entertainment + browsing),
        top_transitions (most common app switch pairs).
    """
    return await _get_db().get_distraction_patterns(period)


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
