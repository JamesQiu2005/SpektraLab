// PreviewController's half-frame pairs: the macOS Session's pair (Model/
// Session.swift "the half-frame pair", :4180-5200; Session+FilmEdge.swift
// :280-298) on the Windows controller. A file of its own so the rest of the
// controller is touched only by hooks: an item whose `pair` is set opens,
// develops, saves, undoes and exports through the functions here.
//
// The model is HalfFramePair.hpp: the item's settings are the film's, the
// pair holds the piece and each frame's own state, and the rails show one
// settings object built from the film and the picked frame (pairs::shown) --
// every edit of it is put back where it belongs when the item is saved
// (savePairSettings, pairs::takeEdit), so each existing control acts on the
// picked frame alone with no change of its own. The host composes and
// develops the piece (PreviewHost::render_pair).
#include "PreviewController.hpp"
#include "FrameImage.hpp"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMetaObject>
#include <algorithm>
#include <cmath>

namespace {
namespace desktop = spk::desktop;
namespace pairs = spk::desktop::pairs;
namespace output = desktop::output;
namespace editing = desktop::editing;
using pairs::Layer;

QString text(const std::string& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }
std::filesystem::path nativePath(const QString& p) { return std::filesystem::path(QDir::toNativeSeparators(p).toStdWString()); }
int sideOf(const QString& s) { return s == QLatin1String("first") ? 0 : s == QLatin1String("second") ? 1 : -1; }
QString sideName(int s) { return s == 0 ? QStringLiteral("first") : s == 1 ? QStringLiteral("second") : QString(); }
QString layerName(Layer l) {
    return l == Layer::first ? QStringLiteral("first") : l == Layer::second ? QStringLiteral("second") : QStringLiteral("film");
}
Layer layerOf(int side) { return side == 0 ? Layer::first : side == 1 ? Layer::second : Layer::film; }
QVariantMap rectMap(const desktop::PairRect& r) { return {{"x", r.x}, {"y", r.y}, {"width", r.w}, {"height", r.h}}; }
QVariantMap placementMap(const desktop::PairPlacement& p) {
    return {{"scale", p.scale}, {"x", p.x}, {"y", p.y}, {"quarterTurns", p.quarter_turns}};
}
bool samePath(const QString& a, const QString& b) {
    return QDir::cleanPath(QDir::fromNativeSeparators(a)).compare(QDir::cleanPath(QDir::fromNativeSeparators(b)), Qt::CaseInsensitive) == 0;
}
// As PreviewController.cpp's: the brightness round-trips through stops.
bool sameRender(desktop::RenderSettings a, desktop::RenderSettings b) {
    const bool exposure = std::abs(a.print_exposure - b.print_exposure) < 1e-12;
    a.print_exposure = b.print_exposure;
    return exposure && a == b;
}
}  // namespace

// --- the hooks ---------------------------------------------------------------

bool PreviewController::pairActive() const {
    return active_index_ >= 0 && active_index_ < int(library_.size()) && library_[active_index_].pair.has_value();
}

desktop::RenderSettings PreviewController::pairShown() const {
    const auto& item = library_[active_index_];
    return pairs::shown(item.settings, *item.pair, pair_layer_, pair_camera_side_);
}

editing::State PreviewController::pairState() const {
    const auto& item = library_[active_index_];
    auto film = item.settings;
    auto pair = *item.pair;
    pairs::takeEdit(settings(), film, pair, pair_layer_, pair_camera_side_);
    editing::State state;
    state.settings = film;
    state.mode = decode_mode_ ? desktop::DecodeMode::headroom : desktop::DecodeMode::compatible16;
    state.pair = pair;
    return state;
}

bool PreviewController::pairDirty() const {
    if (!frame_ || !frame_->pair) return true;
    const auto& item = library_[active_index_];
    if (frame_->source != nativePath(item.url.toLocalFile())) return true;
    const auto state = pairState();
    if (frame_->decode_mode != state.mode) return true;
    if (!sameRender(pairs::engineSettings(state.settings, *state.pair), frame_->settings)) return true;
    return !(pairs::engineInput(state.settings, *state.pair) == frame_->pair_input);
}

void PreviewController::savePairSettings(bool recordHistory) {
    auto& item = library_[active_index_];
    const auto state = pairState();
    const bool changed = !sameRender(item.settings, state.settings) || !(state.pair == item.pair) || item.mode != state.mode;
    if (changed) {
        if (recordHistory) recordEdit(item, itemState(item));
        item.thumbnail = {};
        item.pending_save = true;
    }
    item.settings = state.settings;
    item.pair = state.pair;
    item.mode = state.mode;
    item.geometry = {};
    item.held.reset();
    // The rails follow the model: an edit may have moved what they show
    // (the film's print on + Film, a frame given a print of its own).
    const auto shown = pairShown();
    if (!sameRender(shown, settings())) loadSettings(shown, item.mode);
    {
        std::lock_guard lock(pair_fit_mutex_);
        const int side = pairs::cameraSide(*item.pair, pair_layer_, pair_camera_side_);
        pair_fit_.side = side;
        if (side >= 0) {
            pair_fit_.highlight = std::get<double>(item.pair->holes[side]->frame.get("scene_latitude_highlight_pull_back"));
            pair_fit_.shadow = std::get<double>(item.pair->holes[side]->frame.get("scene_latitude_shadow_pull_back"));
        }
    }
    if (changed) {
        scheduleSave();
        emit libraryChanged();
        emit historyChanged();
    }
}

void PreviewController::openPairItem(int index) {
    auto& item = library_.at(index);
    // The frames' own crops, read again: a frame cropped by itself is cropped
    // in the pair (Session.adoptPair, :4222-4233). The photographs' records
    // are only read -- the one in the strip, else the store's.
    bool moved = false;
    for (auto& hole : item.pair->holes) {
        if (!hole) continue;
        std::optional<output::Geometry> own;
        for (int i = 0; i < int(library_.size()) && !own; ++i)
            if (!library_[i].pair && samePath(library_[i].url.toLocalFile(), hole->path))
                own = i == active_index_ ? geometry_ : library_[i].geometry;
        if (!own && QFileInfo(hole->path).isFile()) {
            const auto stored = edit_store_.load(QUrl::fromLocalFile(hole->path), catalog_);
            if (stored.state) own = stored.state->geometry;
        }
        if (own && *own != hole->geometry) { hole->geometry = *own; moved = true; }
    }
    if (moved) { item.pending_save = true; scheduleSave(); }
    pair_placing_ = false;
    pair_drag_.reset();
    pair_commit_.stop();
    pair_layer_ = Layer::film;
    pair_camera_side_ = pairs::cameraSide(*item.pair, Layer::film, 0);
    {
        std::lock_guard lock(pair_fit_mutex_);
        pair_fit_ = {};
        pair_fit_.side = pair_camera_side_;
    }
    const auto identity = nativePath(item.url.toLocalFile());
    const auto s = pairs::engineSettings(item.settings, *item.pair);
    const auto in = pairs::engineInput(item.settings, *item.pair);
    const auto mode = item.mode;
    const auto gen = ++generation_;
    const auto factory = image_factory_;
    submit([identity, s, in, mode, gen, index, factory](desktop::PreviewHost& host) {
        Reply r;
        r.generation = gen;
        r.operation = "open";
        r.library_index = index;
        try {
            r.frame = host.render_pair(identity, in, mode, s);
            r.publication = publish(factory, r.frame, {});
        } catch (const std::exception& e) {
            r.frame = nullptr;
            r.error = text(e.what());
        }
        return r;
    }, uiText("status.opening"), "open");
}

void PreviewController::applyPair() {
    const auto& item = library_[active_index_];
    const auto state = pairState();
    const auto identity = nativePath(item.url.toLocalFile());
    const auto s = pairs::engineSettings(state.settings, *state.pair);
    const auto in = pairs::engineInput(state.settings, *state.pair);
    const auto mode = state.mode;
    const auto gen = ++generation_;
    const auto revision = settings_revision_.load();
    const auto factory = image_factory_;
    submit([this, identity, s, in, mode, gen, revision, factory](desktop::PreviewHost& host) {
        Reply r;
        r.generation = gen;
        r.settings_revision = revision;
        r.operation = "render";
        try {
            r.frame = host.render_pair(identity, in, mode, s);
            if (settings_revision_.load() == revision) r.publication = publish(factory, r.frame, {});
        } catch (const std::exception& e) {
            r.frame = nullptr;
            r.error = text(e.what());
        }
        return r;
    }, uiText("status.rendering"), "render");
}

int PreviewController::insertItem(LibraryItem item, int at) {
    at = std::clamp(at, 0, int(library_.size()));
    library_.insert(library_.begin() + at, std::move(item));
    if (active_index_ >= at) ++active_index_;
    if (gesture_index_ >= at) ++gesture_index_;
    emit libraryChanged();
    return at;
}

int PreviewController::addPairFile(const QString& path) {
    for (int i = 0; i < int(library_.size()); ++i)
        if (samePath(library_[i].url.toLocalFile(), path)) return i;
    editing::State state;
    const auto loaded = pairs::load(path, catalog_.films.empty() ? nullptr : &catalog_, state);
    if (!loaded.pair) {
        status_ = QFileInfo(path).fileName() + QStringLiteral(": ") + loaded.warning;
        emit stateChanged();
        return -1;
    }
    LibraryItem item;
    item.url = QUrl::fromLocalFile(path);
    item.settings = state.settings;
    item.mode = state.mode;
    item.pair = loaded.pair;
    item.has_stored = true;
    item.preserved = loaded.preserved;
    // Not in the selection by itself: a pair found beside its frames is not
    // picked for Sync or export until the user picks it.
    item.selected = false;
    // After its first frame (answer B8), else at the end.
    int at = int(library_.size());
    for (const auto& hole : loaded.pair->holes) {
        if (!hole) continue;
        for (int i = 0; i < int(library_.size()); ++i)
            if (!library_[i].pair && samePath(library_[i].url.toLocalFile(), hole->path)) { at = i + 1; break; }
        break;
    }
    return insertItem(std::move(item), at);
}

void PreviewController::adoptPairs() {
    QStringList folders;
    for (const auto& item : library_)
        if (!item.pair) {
            const auto folder = QFileInfo(item.url.toLocalFile()).absolutePath();
            if (!folders.contains(folder, Qt::CaseInsensitive)) folders.append(folder);
        }
    for (const auto& folder : folders)
        for (const auto& path : pairs::pairsIn(edit_directory_, folder)) addPairFile(path);
}

void PreviewController::savePair(LibraryItem& item) {
    try {
        pairs::save(item.url.toLocalFile(), *item.pair, itemState(item));
        item.pending_save = false;
        item.has_stored = true;
        item.save_warning.clear();
    } catch (const std::exception& e) {
        item.save_warning = text(e.what());
    }
}

void PreviewController::restorePair(const editing::State& target) {
    auto& item = library_[active_index_];
    item.pair = target.pair;
    item.settings = target.settings;
    item.mode = target.mode;
    item.pending_save = true;
    item.thumbnail = {};
    pair_drag_.reset();
    loadSettings(pairShown(), target.mode);
    scheduleSave();
    emit pairChanged();
}

desktop::FramePtr PreviewController::developPair(desktop::PreviewHost& host, const LibraryItem& item,
                                                 const desktop::FramePtr& shown) const {
    // A pair with an empty hole is not exported (answer B9, HalfFramePair.isComplete).
    if (!item.pair->complete()) throw std::runtime_error("A half-frame pair exports with a photograph in each hole");
    const auto identity = nativePath(item.url.toLocalFile());
    const auto s = pairs::engineSettings(item.settings, *item.pair);
    const auto in = pairs::engineInput(item.settings, *item.pair);
    if (shown && shown->pair && shown->source == identity && shown->decode_mode == item.mode && shown->pair_input == in &&
        sameRender(shown->settings, s))
        return shown;
    return host.render_pair(identity, in, item.mode, s);
}

const spk::io::RawMetadata* PreviewController::shotMetadata() const {
    if (!frame_) return nullptr;
    if (frame_->pair) {
        if (!pairActive()) return nullptr;
        const int side = pairs::cameraSide(*library_[active_index_].pair, pair_layer_, pair_camera_side_);
        return side >= 0 && frame_->pair_filled[side] ? &frame_->pair_metadata[side] : nullptr;
    }
    return &frame_->metadata;
}

desktop::RenderSettings PreviewController::measurable(const desktop::RenderSettings& shown) const {
    if (!pairActive()) return shown;
    const auto& item = library_[active_index_];
    auto film = item.settings;
    auto pair = *item.pair;
    pairs::takeEdit(shown, film, pair, pair_layer_, pair_camera_side_);
    return pairs::engineSettings(film, pair);
}

void PreviewController::pairFitRequest(const desktop::FramePtr& frame, spk::Json& request) {
    // On the worker. The Fit on one frame (API-SPEC "The Fit on one frame"):
    // the camera frame's hole, normalised to the piece the engine was handed,
    // and that frame's own pull-backs (Session.pairFitRegion, :4834-4839).
    if (!frame || !frame->pair) return;
    PairFit fit;
    {
        std::lock_guard lock(pair_fit_mutex_);
        fit = pair_fit_;
    }
    if (fit.side < 0 || !frame->pair_filled[fit.side]) return;
    const bool turned = frame->pair_input.turned;
    const auto layout = desktop::pair_layout(turned ? frame->decode_width : frame->decode_height, frame->pair_input.spacing_mm, turned);
    const auto r = layout.normalised(fit.side);
    spk::Json region = spk::Json::array();
    for (const double v : {r.x, r.y, r.x + r.w, r.y + r.h}) region.push(spk::Json(std::clamp(v, 0.0, 1.0)));
    request.set("region", region);
    request.set("highlight_pull_back", spk::Json(fit.highlight));
    request.set("shadow_pull_back", spk::Json(fit.shadow));
}

std::optional<QVariantMap> PreviewController::pairMetering() const {
    if (!frame_ || !frame_->pair || !pairActive()) return std::nullopt;
    const auto& pair = *library_[active_index_].pair;
    const int side = pairs::cameraSide(pair, pair_layer_, pair_camera_side_);
    if (side < 0 || !frame_->pair_filled[side] || !std::get<bool>(pair.holes[side]->frame.get("auto_exposure")))
        return QVariantMap{{"available", false}};
    // What the meter chose for this picture alone (Session.pairExposure).
    const double ev = frame_->pair_metered[side];
    return QVariantMap{{"available", true}, {"exposureEv", ev},
                       {"label", QStringLiteral("auto %1 EV").arg(QString::asprintf("%+.1f", ev))},
                       {"byMethod", QVariantMap()}, {"solveMs", 0.0}};
}

void PreviewController::requestPairAnalysis() {
    if (!frame_ || !frame_->pair) return;
    // The worker measures the frame again after this job (workerLoop's
    // analyse), now with the newly picked frame's hole as the region.
    {
        std::lock_guard lock(mutex_);
        jobs_.push_back([this](desktop::PreviewHost&) {
            analysed_.reset();
            Reply r;
            r.operation = "pair-analysis";
            return r;
        });
    }
    wake_.notify_one();
}

// --- the view ------------------------------------------------------------------

desktop::PairRect PreviewController::pairHoleRect(int side) const {
    if (!pairActive() || side < 0 || side > 1) return {};
    const auto& item = library_[active_index_];
    if (frame_ && frame_->pair && frame_->source == nativePath(item.url.toLocalFile())) return frame_->pair_holes[side];
    const bool strip = std::get<bool>(item.settings.get("overscan_active"));
    return desktop::pair_layout(2400, item.pair->effectiveSpacing(strip), item.pair->turned).normalised(side);
}

QVariantMap PreviewController::pair() const {
    if (!pairActive()) return {{"active", false}};
    const auto& item = library_[active_index_];
    const auto state = pairState();
    const auto& p = *state.pair;
    const bool strip = std::get<bool>(state.settings.get("overscan_active"));
    const bool shownHere = frame_ && frame_->pair && frame_->source == nativePath(item.url.toLocalFile());
    QVariantList holes;
    for (int side = 0; side < 2; ++side) {
        QVariantMap h{{"side", sideName(side)}, {"filled", bool(p.holes[side])}, {"rect", rectMap(pairHoleRect(side))}};
        if (const auto& hole = p.holes[side]) {
            h["exists"] = QFileInfo(hole->path).isFile();
            h["name"] = QFileInfo(hole->path).fileName();
            h["path"] = QDir::toNativeSeparators(hole->path);
            h["placement"] = placementMap(hole->placement);
            h["ownPrint"] = hole->print.has_value();
            h["printScope"] = hole->printScope == pairs::Scope::film ? "film" : "frame";
            h["exposureScope"] = hole->exposureScope == pairs::Scope::film ? "film" : "frame";
            h["metered"] = shownHere ? frame_->pair_metered[side] : 0.0;
        }
        holes.push_back(h);
    }
    QVariantMap drag{{"active", false}};
    if (pair_drag_ && shownHere && frame_->pair_input.holes[pair_drag_->side]) {
        const auto m = desktop::pair_motion(frame_->pair_input.holes[pair_drag_->side]->placement, pair_drag_->live,
                                            pair_drag_->sourceWidth, pair_drag_->sourceHeight,
                                            desktop::pair_hole_aspect(frame_->pair_input.turned));
        drag = {{"active", true}, {"side", sideName(pair_drag_->side)}, {"scale", m.scale},
                {"offsetX", m.offset_x}, {"offsetY", m.offset_y}, {"placement", placementMap(pair_drag_->live)}};
    }
    QVariantList candidates;
    for (int i = 0; i < int(library_.size()); ++i) {
        if (library_[i].pair) continue;
        const auto path = library_[i].url.toLocalFile();
        bool used = false;
        for (const auto& hole : p.holes) used = used || (hole && samePath(hole->path, path));
        candidates.push_back(QVariantMap{{"index", i}, {"name", QFileInfo(path).fileName()}, {"used", used},
                                         {"thumbnail", library_[i].thumbnail}});
    }
    const int camera = pairs::cameraSide(p, pair_layer_, pair_camera_side_);
    return {{"active", true}, {"title", pairs::title(item.url.toLocalFile())}, {"turned", p.turned},
            {"spacing", p.effectiveSpacing(strip)}, {"userSpacing", p.spacingMM}, {"onStrip", strip},
            {"complete", p.complete()}, {"filled", p.filled()}, {"layer", layerName(pair_layer_)},
            {"cameraSide", sideName(camera)}, {"placing", pair_placing_}, {"holes", holes}, {"drag", drag},
            {"candidates", candidates}, {"shown", shownHere}};
}

bool PreviewController::canMakePair() const {
    if (!ready_ || busy_ || dialog_open_) return false;
    return std::any_of(library_.begin(), library_.end(), [](const LibraryItem& i) { return !i.pair; });
}

bool PreviewController::canEnterPair() const {
    // Session.canEnterPair (:4714-4717): a half frame on the canvas.
    if (!ready_ || busy_ || dialog_open_ || !frame_ || active_index_ < 0 || pairActive()) return false;
    return std::get<std::string>(extra_settings_.get("overscan_format")) == "135_half";
}

// --- making a pair --------------------------------------------------------------

bool PreviewController::newPair() {
    if (!canMakePair()) return false;
    // The picked photographs in the filmstrip's order (Session.newPair,
    // :4271-4279; selectedFrames, :61).
    std::vector<int> picks;
    for (int i = 0; i < int(library_.size()) && picks.size() < 2; ++i)
        if (library_[i].selected && !library_[i].pair) picks.push_back(i);
    const int first = picks.empty() ? -1 : picks[0];
    const int second = picks.size() > 1 ? picks[1] : -1;
    const int look = first >= 0 ? first : -1;
    const auto own = look < 0 ? desktop::RenderSettings() : look == active_index_ ? settings() : library_[look].settings;
    // A landscape first frame is the camera turned: the holes are stacked.
    bool turned = true;
    if (first >= 0) {
        QSize size;
        if (first == active_index_ && frame_ && !pairActive()) {
            const auto d = decodeSize();
            std::uint32_t w = 0, h = 0;
            desktop::cut_size({geometry_.crop.x(), geometry_.crop.y(), geometry_.crop.width(), geometry_.crop.height(),
                               geometry_.quarterTurns, geometry_.flipHorizontal, geometry_.flipVertical,
                               geometry_.straightenDegrees}, std::uint32_t(d.width()), std::uint32_t(d.height()), w, h);
            size = QSize(int(w), int(h));
        } else if (!library_[first].thumbnail.isNull()) {
            size = library_[first].thumbnail.size();
        }
        if (!size.isEmpty()) turned = size.width() > size.height();
    }
    makePair(first, second, own, turned, false);
    return true;
}

bool PreviewController::enterPair() {
    if (!canEnterPair()) return false;
    // Session.enterPair (:4724-4733): the photograph becomes the first hole,
    // cut as it is cut; the piece takes its look, its film edge on Half, and
    // its orientation.
    const auto d = decodeSize();
    std::uint32_t w = std::uint32_t(d.width()), h = std::uint32_t(d.height());
    if (std::get<bool>(extra_settings_.get("overscan_active")))
        desktop::cut_size({geometry_.crop.x(), geometry_.crop.y(), geometry_.crop.width(), geometry_.crop.height(),
                           geometry_.quarterTurns, geometry_.flipHorizontal, geometry_.flipVertical,
                           geometry_.straightenDegrees}, std::uint32_t(d.width()), std::uint32_t(d.height()), w, h);
    makePair(active_index_, -1, settings(), w > h, true);
    return true;
}

void PreviewController::makePair(int first, int second, desktop::RenderSettings look, bool turned, bool keepFilmEdge) {
    if (busy_ || !ready_) return;
    endEditGesture();
    saveActiveSettings();
    int anchor = first;
    for (int i = 0; i < int(library_.size()) && anchor < 0; ++i)
        if (!library_[i].pair) anchor = i;
    if (anchor < 0) return;
    const auto folder = QFileInfo(library_[anchor].url.toLocalFile()).absolutePath();
    pairs::Pair p;
    p.folder = folder;
    p.turned = turned;
    const auto holeOf = [&](int i) {
        const auto& it = library_[i];
        const auto own = i == active_index_ ? settings() : it.settings;
        return pairs::holeFor(it.url.toLocalFile(), &own, i == active_index_ ? geometry_ : it.geometry);
    };
    if (first >= 0) p.holes[0] = holeOf(first);
    if (second >= 0) p.holes[1] = holeOf(second);
    // The pair's own settings start as its first frame's look (Session.makePair,
    // :4751-4764). Each frame keeps its own camera and placement; the film
    // edge comes along only on the way in from a half frame, and on Half.
    desktop::RenderSettings film = look;
    const desktop::RenderSettings defaults;
    for (const auto& key : pairs::cameraKeys()) film.set(key, defaults.get(key));
    if (!keepFilmEdge)
        for (const auto& field : desktop::setting_fields())
            if (desktop::per_photo_setting(field.key)) film.set(field.key, field.initial);
    film.set("overscan_format", std::string("135_half"));
    const auto path = pairs::newPairPath(edit_directory_, folder);
    const auto utf8 = QDir::toNativeSeparators(path).toUtf8();
    desktop::seed_film_edge(film, std::string_view(utf8.constData(), std::size_t(utf8.size())), first >= 0 ? first : -1,
                            bodySeed());
    editing::State state;
    state.settings = film;
    state.mode = first >= 0 ? library_[first].mode : desktop::DecodeMode::compatible16;
    state.pair = p;
    try {
        pairs::save(path, p, state);
    } catch (const std::exception& e) {
        status_ = text(e.what());
        emit stateChanged();
        return;
    }
    LibraryItem item;
    item.url = QUrl::fromLocalFile(path);
    item.settings = film;
    item.mode = state.mode;
    item.pair = p;
    item.has_stored = true;
    item.selected = false;
    const int index = insertItem(std::move(item), first >= 0 ? first + 1 : int(library_.size()));
    openItem(index);
    // An empty second hole is the next thing to fill: it is picked.
    if (p.holes[0] && !p.holes[1]) pair_layer_ = Layer::second;
    status_ = uiText(p.filled() == 2 ? "status.pairMade" : "status.pairAddSecond");
    emit stateChanged();
    emit pairChanged();
}

bool PreviewController::deletePair(int index) {
    if (busy_ || dialog_open_ || index < 0 || index >= int(library_.size()) || !library_[index].pair) return false;
    const auto path = library_[index].url.toLocalFile();
    // The pair's own record: the photographs it showed are untouched
    // (Session.deletePair, :4291-4297).
    if (QFileInfo::exists(path) && !QFile::remove(path)) return false;
    const bool wasActive = index == active_index_;
    if (gesture_index_ == index) endEditGesture();
    library_.erase(library_.begin() + index);
    if (active_index_ > index) --active_index_;
    else if (wasActive) active_index_ = -1;
    if (gesture_index_ > index) --gesture_index_;
    emit libraryChanged();
    if (wasActive && !library_.empty()) openItem(std::min(index, int(library_.size()) - 1));
    return true;
}

// --- picking --------------------------------------------------------------------

void PreviewController::setPairLayerIndex(Layer layer) {
    if (!pairActive() || layer == pair_layer_) return;
    endEditGesture();
    saveActiveSettings();  // the rails' edits land on the layer they were made on
    const auto& item = library_[active_index_];
    const int before = pairs::cameraSide(*item.pair, pair_layer_, pair_camera_side_);
    pair_layer_ = layer;
    if (layer != Layer::film && item.pair->holes[int(layer) - 1]) pair_camera_side_ = int(layer) - 1;
    const int after = pairs::cameraSide(*item.pair, pair_layer_, pair_camera_side_);
    // The crop mode is a frame's: picking the film or an empty hole ends it.
    if (pair_placing_ && (layer == Layer::film || !item.pair->holes[int(layer) - 1])) {
        commitPairDrag();
        pair_placing_ = false;
    }
    loadSettings(pairShown(), item.mode);
    saveActiveSettings();
    if (before != after) requestPairAnalysis();
    emit pairChanged();
}

void PreviewController::setPairLayer(const QString& layer) {
    setPairLayerIndex(layer == QLatin1String("first") ? Layer::first : layer == QLatin1String("second") ? Layer::second : Layer::film);
}

QString PreviewController::pairHoleAt(double x, double y) const {
    for (int side = 0; side < 2; ++side)
        if (pairHoleRect(side).contains(x, y)) return sideName(side);
    return {};
}

void PreviewController::pairClicked(double x, double y) {
    // Session.clicked(normalised:) (:4510-4517): the hole under the pointer,
    // anywhere else on the piece the film.
    if (!pairActive()) return;
    setPairLayerIndex(layerOf(sideOf(pairHoleAt(x, y))));
}

// --- the piece's edits ------------------------------------------------------------

void PreviewController::editPair(const std::function<void(pairs::Pair&, desktop::RenderSettings&)>& change,
                                 const QString& editKey) {
    if (!pairActive() || !settingsEditable()) return;
    if (gesture_index_ >= 0 && gesture_key_ != editKey) endEditGesture();
    saveActiveSettings();
    auto& item = library_[active_index_];
    auto pair = *item.pair;
    auto film = item.settings;
    change(pair, film);
    if (pair == *item.pair && sameRender(film, item.settings)) return;
    // One undo step (a slider between beginEditGesture and endEditGesture is
    // one), as Session.updatePair's pushUndo.
    recordEdit(item, itemState(item));
    item.pair = pair;
    item.settings = film;
    item.pending_save = true;
    item.thumbnail = {};
    loadSettings(pairShown(), item.mode);
    ++settings_revision_;
    auto_apply_.stop();
    schedulePreview();
    scheduleSave();
    failed_ = false;
    status_ = uiText("status.updatingPreview");
    emit libraryChanged();
    emit historyChanged();
    emit stateChanged();
    emit pairChanged();
}

bool PreviewController::setPairFrame(const QString& sideText, int libraryIndex) {
    const int side = sideOf(sideText);
    if (!pairActive() || side < 0 || libraryIndex < 0 || libraryIndex >= int(library_.size()) || library_[libraryIndex].pair)
        return false;
    const auto& it = library_[libraryIndex];
    const auto hole = pairs::holeFor(it.url.toLocalFile(), &it.settings, it.geometry);
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) { p.holes[side] = hole; }, QStringLiteral("pairFrame"));
    setPairLayerIndex(layerOf(side));
    return true;
}

void PreviewController::removePairFrame(const QString& sideText) {
    const int side = sideOf(sideText);
    if (side < 0) return;
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) { p.holes[side].reset(); }, QStringLiteral("pairFrame"));
}

void PreviewController::swapPairFrames() {
    editPair([](pairs::Pair& p, desktop::RenderSettings&) { std::swap(p.holes[0], p.holes[1]); }, QStringLiteral("pairSwap"));
}

void PreviewController::setPairTurned(bool turned) {
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) { p.turned = turned; }, QStringLiteral("pairTurned"));
}

void PreviewController::setPairSpacing(double mm) {
    if (!std::isfinite(mm)) return;
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) { p.spacingMM = std::clamp(mm, desktop::kPairSpacingMin, desktop::kPairSpacingMax); },
             QStringLiteral("pairSpacing"));
}

void PreviewController::turnPairPicture(const QString& sideText) {
    const int side = sideOf(sideText);
    if (side < 0) return;
    pair_drag_.reset();
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) {
        if (p.holes[side]) p.holes[side]->placement.quarter_turns = (p.holes[side]->placement.quarter_turns + 1) % 4;
    }, QStringLiteral("pairTurn"));
}

void PreviewController::resetPairPlacement(const QString& sideText) {
    const int side = sideOf(sideText);
    if (side < 0) return;
    pair_drag_.reset();
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) { if (p.holes[side]) p.holes[side]->placement = {}; },
             QStringLiteral("pairPlacement"));
}

void PreviewController::resetPairEnlarger() {
    // Session.resetEnlarger (:5068-5086): the picked frame's own print back to
    // neutral, both frames keeping a print of their own; with the film picked
    // the piece is one print again, the film's, neutral.
    const auto layer = pair_layer_;
    editPair([layer](pairs::Pair& p, desktop::RenderSettings& film) {
        desktop::RenderSettings neutral;
        neutral.print_exposure = 1.0;
        neutral.y_filter_shift = 0;
        neutral.m_filter_shift = 0;
        neutral.set("preflash_exposure", 0.0);
        const int side = layer != Layer::film && p.holes[int(layer) - 1] ? int(layer) - 1 : -1;
        if (side >= 0) {
            for (auto& hole : p.holes)
                if (hole && !hole->print) {
                    hole->print = desktop::RenderSettings();
                    for (const auto& key : pairs::printKeys()) hole->print->set(key, film.get(key));
                }
            for (const auto& key : pairs::printKeys()) p.holes[side]->print->set(key, neutral.get(key));
        } else {
            for (auto& hole : p.holes)
                if (hole) hole->print.reset();
            for (const auto& key : pairs::printKeys()) film.set(key, neutral.get(key));
        }
    }, QStringLiteral("enlarger"));
}

void PreviewController::setPairScope(const QString& which, const QString& scope) {
    if (!pairActive()) return;
    const auto value = scope == QLatin1String("film") ? pairs::Scope::film : pairs::Scope::frame;
    const auto& item = library_[active_index_];
    // The Enlarger's is the picked frame's; Input / Camera's the camera frame's.
    const int side = which == QLatin1String("print")
        ? (pair_layer_ != Layer::film && item.pair->holes[int(pair_layer_) - 1] ? int(pair_layer_) - 1 : -1)
        : pairs::cameraSide(*item.pair, pair_layer_, pair_camera_side_);
    if (side < 0) return;
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) {
        if (which == QLatin1String("print")) p.holes[side]->printScope = value;
        else p.holes[side]->exposureScope = value;
    }, QStringLiteral("pairScope"));
}

void PreviewController::openPairFrameAlone(const QString& sideText) {
    // Session.openHoleAlone (:4855-4859): leave the pair for one of its frames.
    const int side = sideOf(sideText);
    if (!pairActive() || side < 0 || busy_) return;
    const auto& hole = library_[active_index_].pair->holes[side];
    if (!hole || !QFileInfo(hole->path).isFile()) return;
    for (int i = 0; i < int(library_.size()); ++i)
        if (!library_[i].pair && samePath(library_[i].url.toLocalFile(), hole->path)) { selectImage(i); return; }
    openRaw(QUrl::fromLocalFile(hole->path));
}

// --- the crop mode inside a hole ----------------------------------------------------

void PreviewController::setPairPlacing(bool on) {
    if (!pairActive()) { pair_placing_ = false; return; }
    if (!on) {
        commitPairDrag();
        pair_placing_ = false;
        emit pairChanged();
        return;
    }
    // The picked frame, or the first hole that has one; nothing to crop in an
    // empty pair (Session.togglePairPlacing, :4521-4535).
    const auto& p = *library_[active_index_].pair;
    if (pair_layer_ == Layer::film || !p.holes[int(pair_layer_) - 1]) {
        const int filled = p.holes[0] ? 0 : p.holes[1] ? 1 : -1;
        if (filled < 0) return;
        setPairLayerIndex(layerOf(filled));
    }
    pair_placing_ = true;
    emit pairChanged();
}

bool PreviewController::beginPairDrag(double x, double y) {
    if (!pair_placing_ || !pairActive() || pair_layer_ == Layer::film || !frame_ || !frame_->pair) return false;
    const int side = int(pair_layer_) - 1;
    const auto& hole = library_[active_index_].pair->holes[side];
    if (!hole || !frame_->pair_picture_w[side] || !pairHoleRect(side).contains(x, y)) return false;
    pair_commit_.stop();
    // A drag that follows a zoom carries on from where the zoom has it.
    const auto origin = pair_drag_ && pair_drag_->side == side && !pair_drag_->settling &&
                                pair_drag_->live.quarter_turns == hole->placement.quarter_turns
                            ? pair_drag_->live : hole->placement;
    pair_drag_ = PairDrag{side, QPointF(x, y), origin, origin, double(frame_->pair_picture_w[side]),
                          double(frame_->pair_picture_h[side]), false};
    emit pairChanged();
    return true;
}

void PreviewController::movePairDrag(double x, double y) {
    if (!pair_drag_ || pair_drag_->settling || !frame_ || !frame_->pair) return;
    const auto r = pairHoleRect(pair_drag_->side);
    if (r.w <= 0 || r.h <= 0) return;
    pair_drag_->live = desktop::pair_placement_dragged(pair_drag_->origin, (x - pair_drag_->start.x()) / r.w,
                                                       (y - pair_drag_->start.y()) / r.h, pair_drag_->sourceWidth,
                                                       pair_drag_->sourceHeight, desktop::pair_hole_aspect(frame_->pair_input.turned));
    emit pairChanged();
}

void PreviewController::endPairDrag() { commitPairDrag(); }

bool PreviewController::zoomPairPlacement(double factor, double x, double y) {
    // Session.placementZoomed (:4636-4648): about the pointer, or the hole's
    // middle when the pointer is off it; every scroll in the mode is this.
    if (!pair_placing_ || !pairActive() || pair_layer_ == Layer::film || !frame_ || !frame_->pair ||
        !std::isfinite(factor) || factor <= 0)
        return false;
    const int side = int(pair_layer_) - 1;
    const auto& hole = library_[active_index_].pair->holes[side];
    if (!hole || !frame_->pair_picture_w[side]) return false;
    if (!pair_drag_ || pair_drag_->side != side || pair_drag_->settling ||
        pair_drag_->live.quarter_turns != hole->placement.quarter_turns)
        pair_drag_ = PairDrag{side, QPointF(x, y), hole->placement, hole->placement, double(frame_->pair_picture_w[side]),
                              double(frame_->pair_picture_h[side]), false};
    const auto r = pairHoleRect(side);
    double ax = 0.5, ay = 0.5;
    if (r.w > 0 && r.h > 0 && r.contains(x, y)) { ax = (x - r.x) / r.w; ay = (y - r.y) / r.h; }
    pair_drag_->live = desktop::pair_placement_zoomed(pair_drag_->live, factor, ax, ay, pair_drag_->sourceWidth,
                                                      pair_drag_->sourceHeight, desktop::pair_hole_aspect(frame_->pair_input.turned));
    pair_drag_->origin = pair_drag_->live;
    pair_commit_.start();
    emit pairChanged();
    return true;
}

void PreviewController::previewPairPlacement(const QString& sideText, double scale, double x, double y) {
    const int side = sideOf(sideText);
    if (!pairActive() || side < 0 || !frame_ || !frame_->pair || !frame_->pair_picture_w[side]) return;
    const auto& hole = library_[active_index_].pair->holes[side];
    if (!hole) return;
    auto live = desktop::clamped({scale, x, y, hole->placement.quarter_turns});
    pair_drag_ = PairDrag{side, QPointF(), live, live, double(frame_->pair_picture_w[side]),
                          double(frame_->pair_picture_h[side]), false};
    pair_commit_.start();
    emit pairChanged();
}

void PreviewController::commitPairDrag() {
    // Session.commitPlacement (:4674-4688): one undo step, one save, one
    // develop; the motion stays on the hole until that develop lands.
    pair_commit_.stop();
    if (!pair_drag_ || pair_drag_->settling || !pairActive()) return;
    const int side = pair_drag_->side;
    const auto live = pair_drag_->live;
    const auto& hole = library_[active_index_].pair->holes[side];
    if (!hole || hole->placement == live) { pair_drag_.reset(); emit pairChanged(); return; }
    pair_drag_->settling = true;
    editPair([&](pairs::Pair& p, desktop::RenderSettings&) { if (p.holes[side]) p.holes[side]->placement = live; },
             QStringLiteral("pairPlacement"));
}

void PreviewController::pairFrameLanded() {
    // Session.placementLanded (:4691-4695).
    if (!pair_drag_ || !pair_drag_->settling) return;
    if (!frame_ || !frame_->pair || !frame_->pair_input.holes[pair_drag_->side] ||
        frame_->pair_input.holes[pair_drag_->side]->placement == pair_drag_->live)
        pair_drag_.reset();
}
