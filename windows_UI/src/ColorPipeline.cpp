#include "ColorPipeline.hpp"

#include "ColorLut.hpp"
#include "DisplayColor.hpp"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QGuiApplication>
#include <QPointer>
#include <QQuickWindow>
#include <QScreen>
#include <QThread>
#include <QThreadPool>
#include <QTimer>
#include <QVariant>
#include <QtDebug>
#include <atomic>
#include <list>
#include <set>
#include <utility>

// The window's monitor -> DisplayTarget (DisplayColor.*) -> one LUT per
// source colour space (ColorLut.*), built on a worker thread and cached.
// Everything here runs on the GUI thread, or on the render thread inside
// updatePaintNode while the GUI thread is blocked, so the state needs no lock;
// the worker only ever sees copies of ICC bytes and hands back an immutable LUT.

using namespace spk::color;

namespace {
const char* const kWindowProperty = "_spektralab_color_pipeline";
// Windows announces no profile change; this bounds how long one goes unseen
// when no other trigger fires.
constexpr int kPollMs = 3000;
// Built LUTs kept for reuse, 4.4 MB each: two source spaces on three
// monitors, so dragging a window back and forth never rebuilds.
constexpr std::size_t kCachedLuts = 6;
// Distinct source spaces remembered; sRGB (the first) is never dropped.
constexpr std::size_t kServedSources = 8;

bool colorLog() {
    static const bool enabled = qEnvironmentVariableIntValue("SPEKTRALAB_COLOR_LOG") != 0;
    return enabled;
}

std::shared_ptr<const ColorLut> identityLut() {
    static const auto identity = std::make_shared<const ColorLut>();
    return identity;
}

using LutKey = std::pair<quint64, quint64>; // (source ICC hash, target ICC hash)
} // namespace

struct ColorPipeline::Impl {
    ColorPipeline* q = nullptr;
    QPointer<QQuickWindow> window;
    QString mode = QStringLiteral("automatic");
    QString customProfilePath;
    bool dither = true;
    std::shared_ptr<const ColorLut> override;

    std::shared_ptr<ProfileSource> source = systemProfileSource();
    QString screenId;
    DisplayInfo display;
    ProfileFile custom;
    DisplayTarget target = srgbTarget(QStringLiteral("sRGB (assumed)"));

    // The LUT each source space is drawn with now, and which target it is for.
    // Until a new target's LUT lands, `lut` is still the previous one.
    struct Served {
        QColorSpace space;
        QByteArray icc;
        quint64 hash = 0;
        quint64 targetHash = 0;
        bool current = false;
        std::shared_ptr<const ColorLut> lut;
    };
    std::vector<Served> served;
    std::list<std::pair<LutKey, std::shared_ptr<const ColorLut>>> cache; // most recently used first
    std::set<LutKey> pending;

    QThreadPool* pool = nullptr; // a child of q, so it follows q to the GUI thread
    std::shared_ptr<std::atomic<bool>> cancelled = std::make_shared<std::atomic<bool>>(false);

    Served& servedFor(const QColorSpace& space) {
        for (auto& entry : served)
            if (entry.space == space) return entry;
        if (served.size() >= kServedSources) served.erase(served.begin() + 1);
        Served entry;
        entry.space = space;
        entry.icc = space.iccProfile();
        entry.hash = profileHash(entry.icc);
        served.push_back(std::move(entry));
        return served.back();
    }

    std::shared_ptr<const ColorLut> cached(const LutKey& key) {
        for (auto it = cache.begin(); it != cache.end(); ++it) {
            if (it->first != key) continue;
            cache.splice(cache.begin(), cache, it);
            return cache.front().second;
        }
        return nullptr;
    }

    std::shared_ptr<const ColorLut> resolve(Served& entry) {
        if (entry.current && entry.targetHash == target.hash) return entry.lut;
        std::shared_ptr<const ColorLut> ready;
        if (sameEncoding(entry.space, target.space)) ready = identityLut();
        else ready = cached({entry.hash, target.hash});
        if (!ready) {
            requestBuild(entry);
            return entry.lut ? entry.lut : identityLut();
        }
        entry.lut = std::move(ready);
        entry.targetHash = target.hash;
        entry.current = true;
        return entry.lut;
    }

    void requestBuild(const Served& entry) {
        const LutKey key{entry.hash, target.hash};
        if (!pending.insert(key).second) return;
        // Copies only: the worker parses its own QColorSpace objects from the
        // bytes rather than sharing the GUI thread's.
        const QByteArray sourceIcc = entry.icc, targetIcc = target.icc;
        const QString what = entry.space.description() + QStringLiteral(" -> ") + target.displayName;
        const auto cancel = cancelled;
        ColorPipeline* owner = q;
        pool->start([owner, key, sourceIcc, targetIcc, what, cancel] {
            if (cancel->load()) return;
            QElapsedTimer clock;
            clock.start();
            const QColorSpace from = QColorSpace::fromIccProfile(sourceIcc);
            const QColorSpace to = QColorSpace::fromIccProfile(targetIcc);
            std::shared_ptr<const ColorLut> result = identityLut();
            if (from.isValid() && to.isValid() && !sameEncoding(from, to)) {
                // Curves for a matrix/TRC display, one encoded table otherwise.
                auto built = buildLut(from, to, cancel.get());
                if (!built) return; // cancelled: the pipeline is going away
                if (!isNearIdentity(*built)) result = std::move(built);
            }
            const qint64 ms = clock.elapsed();
            QMetaObject::invokeMethod(owner, [owner, key, result, ms, what] {
                owner->d_->landed(key, result, ms, what);
            }, Qt::QueuedConnection);
        });
    }

    void landed(const LutKey& key, const std::shared_ptr<const ColorLut>& lut, qint64 ms, const QString& what) {
        pending.erase(key);
        cache.emplace_front(key, lut);
        if (cache.size() > kCachedLuts) cache.pop_back();
        if (colorLog())
            qInfo().noquote() << QStringLiteral("color: LUT %1 built in %2 ms (%3)")
                                     .arg(what).arg(ms)
                                     .arg(lut->isIdentity() ? QStringLiteral("identity")
                                          : lut->hasCurves() ? QStringLiteral("%1^3 linear table, %2-entry curves").arg(lut->size).arg(lut->curveSize)
                                                             : QStringLiteral("%1^3 encoded table").arg(lut->size));
        bool used = false;
        for (auto& entry : served) {
            if (entry.hash != key.first || target.hash != key.second) continue;
            entry.lut = lut;
            entry.targetHash = key.second;
            entry.current = true;
            used = true;
        }
        if (used) emit q->changed();
    }

    // Ask again and apply the answer; true when anything a canvas or the
    // status line shows changed.
    bool refresh() {
        display = DisplayInfo();
        display.screenId = screenId;
        if (mode != QLatin1String("srgb") && !screenId.isEmpty() && source) display = source->query(screenId);
        if (mode == QLatin1String("custom")) {
            const QFileInfo file(customProfilePath);
            const qint64 size = file.isFile() ? file.size() : -1;
            const qint64 modified = file.isFile() ? file.lastModified().toMSecsSinceEpoch() : -1;
            if (custom.path != customProfilePath || custom.size != size || custom.modifiedMs != modified)
                custom = readProfileFile(customProfilePath);
        }
        DisplayTarget next = resolveTarget(mode, display, custom);
        if (next == target) return false;
        const bool newSpace = next.hash != target.hash;
        target = std::move(next);
        if (colorLog())
            qInfo().noquote() << QStringLiteral("color: %1 -> %2%3 [%4; %5]")
                                     .arg(screenId, target.displayName,
                                          target.status.isEmpty() ? QString() : QStringLiteral(" (") + target.status + QStringLiteral(")"),
                                          displayModeName(display.mode), display.lookup);
        // Start every source drawn so far on the new target now, rather than
        // when the next paint asks.
        if (newSpace)
            for (auto& entry : served) resolve(entry);
        return true;
    }

    // Timers and connections, on the thread the pipeline lives on.
    void startTracking() {
        auto* poll = new QTimer(q);
        poll->setInterval(kPollMs);
        QObject::connect(poll, &QTimer::timeout, q, &ColorPipeline::reload);
        poll->start();
        if (auto* notifier = DisplayChangeNotifier::instance())
            QObject::connect(notifier, &DisplayChangeNotifier::displayChanged, q, &ColorPipeline::reload);
        if (auto* application = qobject_cast<QGuiApplication*>(QCoreApplication::instance())) {
            QObject::connect(application, &QGuiApplication::screenAdded, q, &ColorPipeline::reload);
            QObject::connect(application, &QGuiApplication::screenRemoved, q, &ColorPipeline::reload);
            QObject::connect(application, &QGuiApplication::applicationStateChanged, q, [this](Qt::ApplicationState state) {
                if (state == Qt::ApplicationActive) q->reload();
            });
        }
        if (window) {
            QObject::connect(window, &QWindow::screenChanged, q, [this](QScreen* screen) {
                screenId = screenIdOf(screen);
                q->reload();
            });
            // The screen may have changed between construction and now.
            const QString now = screenIdOf(window->screen());
            if (now != screenId) {
                screenId = now;
                q->reload();
            }
        }
    }
};

ColorPipeline* ColorPipeline::forWindow(QQuickWindow* window) {
    if (!window) return nullptr;
    if (auto* existing = window->property(kWindowProperty).value<ColorPipeline*>()) return existing;
    auto* pipeline = new ColorPipeline(window);
    window->setProperty(kWindowProperty, QVariant::fromValue(pipeline));
    return pipeline;
}

// forWindow may run on the render thread from updatePaintNode. A QObject
// cannot take a parent in another thread there, and timers cannot start, so
// the pipeline is created parentless, pushed to the window's thread, and
// finishes setting up when that thread's event loop resumes.
ColorPipeline::ColorPipeline(QQuickWindow* window)
    : QObject(window && window->thread() == QThread::currentThread() ? window : nullptr),
      d_(std::make_unique<Impl>()) {
    d_->q = this;
    d_->window = window;
    d_->pool = new QThreadPool(this);
    d_->pool->setMaxThreadCount(1);
    // sRGB is every frame's encoding today: start its LUT before a paint asks.
    d_->servedFor(QColorSpace(QColorSpace::SRgb));
    if (window) d_->screenId = screenIdOf(window->screen());
    d_->refresh();
    for (auto& entry : d_->served) d_->resolve(entry);
    if (!window || window->thread() == QThread::currentThread()) {
        d_->startTracking();
        return;
    }
    moveToThread(window->thread());
    QPointer<QQuickWindow> guard(window);
    QMetaObject::invokeMethod(this, [this, guard] {
        if (!guard) {
            deleteLater();
            return;
        }
        setParent(guard);
        d_->startTracking();
    }, Qt::QueuedConnection);
}

ColorPipeline::~ColorPipeline() {
    // A build in flight finishes (or sees the flag and stops) before the
    // state it reports to is destroyed; its queued report dies with QObject.
    d_->cancelled->store(true);
    d_->pool->waitForDone();
}

std::shared_ptr<const ColorLut> ColorPipeline::lut(const QColorSpace& source) const {
    if (d_->override) return d_->override;
    // A QImage without a colour space is taken as sRGB, as Qt itself does.
    return d_->resolve(d_->servedFor(source.isValid() ? source : QColorSpace(QColorSpace::SRgb)));
}

QString ColorPipeline::mode() const { return d_->mode; }
void ColorPipeline::setMode(const QString& mode) {
    if (mode == d_->mode) return;
    d_->mode = mode;
    d_->refresh();
    emit changed();
}
QString ColorPipeline::customProfilePath() const { return d_->customProfilePath; }
void ColorPipeline::setCustomProfilePath(const QString& path) {
    if (path == d_->customProfilePath) return;
    d_->customProfilePath = path;
    d_->refresh();
    emit changed();
}
QString ColorPipeline::displayName() const { return d_->target.displayName; }
QString ColorPipeline::status() const { return d_->target.status; }
bool ColorPipeline::dither() const { return d_->dither; }
void ColorPipeline::setDither(bool dither) {
    if (dither == d_->dither) return;
    d_->dither = dither;
    emit changed();
}

void ColorPipeline::setLutOverrideForTesting(std::shared_ptr<const ColorLut> lut) {
    d_->override = std::move(lut);
    emit changed();
}

QColorSpace ColorPipeline::targetColorSpace() const { return d_->target.space; }

void ColorPipeline::setProfileSourceForTesting(std::shared_ptr<ProfileSource> source) {
    d_->source = std::move(source);
    reload();
}

void ColorPipeline::setScreenForTesting(const QString& screenId) {
    d_->screenId = screenId;
    reload();
}

void ColorPipeline::reload() {
    if (d_->refresh()) emit changed();
}
