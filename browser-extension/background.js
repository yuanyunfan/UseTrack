// UseTrack URL Tracker — Chrome Extension Background Service Worker

const NATIVE_HOST = "com.usetrack.browser";
let lastUrl = "";
let lastTimestamp = 0;
const MIN_INTERVAL_MS = 2000; // Minimum 2s between events

// Listen for tab activation (switching tabs)
chrome.tabs.onActivated.addListener(async (activeInfo) => {
    try {
        const tab = await chrome.tabs.get(activeInfo.tabId);
        if (tab.url) {
            recordUrl(tab.url, tab.title || "");
        }
    } catch (e) {
        // Tab may have been closed
    }
});

// Listen for URL changes within a tab
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.status === "complete" && tab.active && tab.url) {
        recordUrl(tab.url, tab.title || "");
    }
});

function recordUrl(url, title) {
    // Skip internal pages
    if (
        url.startsWith("chrome://") ||
        url.startsWith("chrome-extension://") ||
        url.startsWith("about:") ||
        url.startsWith("edge://")
    ) {
        return;
    }

    const now = Date.now();

    // Deduplicate: same URL within MIN_INTERVAL
    if (url === lastUrl && now - lastTimestamp < MIN_INTERVAL_MS) {
        return;
    }

    lastUrl = url;
    lastTimestamp = now;

    const message = {
        type: "url_visit",
        url: url,
        title: title,
        timestamp: new Date().toISOString(),
        domain: extractDomain(url),
    };

    // Try Native Messaging first
    try {
        chrome.runtime.sendNativeMessage(NATIVE_HOST, message, (response) => {
            if (chrome.runtime.lastError) {
                // Native host not available, store locally
                storeLocally(message);
            }
        });
    } catch (e) {
        storeLocally(message);
    }
}

function extractDomain(url) {
    try {
        return new URL(url).hostname;
    } catch {
        return "";
    }
}

async function storeLocally(message) {
    // Store in chrome.storage.local for later retrieval
    const result = await chrome.storage.local.get("pendingUrls");
    const pending = result.pendingUrls || [];
    pending.push(message);
    // Keep only last 1000 events
    if (pending.length > 1000) {
        pending.splice(0, pending.length - 1000);
    }
    await chrome.storage.local.set({ pendingUrls: pending });
}

// --- Flush pending URLs periodically ---

const FLUSH_ALARM_NAME = "flushPendingUrls";
const FLUSH_INTERVAL_MINUTES = 5;

// Create alarm on install/startup
chrome.runtime.onInstalled.addListener(() => {
    chrome.alarms.create(FLUSH_ALARM_NAME, { periodInMinutes: FLUSH_INTERVAL_MINUTES });
});

chrome.runtime.onStartup.addListener(() => {
    chrome.alarms.create(FLUSH_ALARM_NAME, { periodInMinutes: FLUSH_INTERVAL_MINUTES });
});

chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === FLUSH_ALARM_NAME) {
        flushPendingUrls();
    }
});

async function flushPendingUrls() {
    const result = await chrome.storage.local.get("pendingUrls");
    const pending = result.pendingUrls || [];
    if (pending.length === 0) return;

    const remaining = [];

    for (const message of pending) {
        const sent = await sendNativeMessage(message);
        if (!sent) {
            // Native host still unavailable, keep remaining messages and stop
            remaining.push(message);
            // Don't try further messages if the host is down
            remaining.push(...pending.slice(pending.indexOf(message) + 1));
            break;
        }
    }

    await chrome.storage.local.set({ pendingUrls: remaining });
}

function sendNativeMessage(message) {
    return new Promise((resolve) => {
        try {
            chrome.runtime.sendNativeMessage(NATIVE_HOST, message, (_response) => {
                if (chrome.runtime.lastError) {
                    resolve(false);
                } else {
                    resolve(true);
                }
            });
        } catch (e) {
            resolve(false);
        }
    });
}
