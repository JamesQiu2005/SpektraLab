#include "PostDevView.hpp"
#include <QColorSpace>
#include <QJsonObject>
#include <QtGui/qrgbafloat.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <stdexcept>
#include <thread>
#include <vector>

namespace spk::desktop::postdev {
namespace {
// Chunks of rows from one counter: a pixel depends only on its value and
// position, never on which thread computed it.
template <class Row>
void forRows(int height, int threads, const Row& row) {
    constexpr int chunk = 16;
    const int chunks = (height + chunk - 1) / chunk;
    int workers = threads > 0 ? threads : int(std::thread::hardware_concurrency());
    workers = std::clamp(workers, 1, std::max(chunks, 1));
    if (workers == 1) {
        for (int y = 0; y < height; ++y) row(y);
        return;
    }
    std::atomic<int> next{0};
    auto work = [&] {
        for (int c = next.fetch_add(1); c < chunks; c = next.fetch_add(1))
            for (int y = c * chunk, end = std::min(height, y + chunk); y < end; ++y) row(y);
    };
    std::vector<std::thread> pool;
    pool.reserve(size_t(workers - 1));
    for (int i = 1; i < workers; ++i) pool.emplace_back(work);
    work();
    for (auto& t : pool) t.join();
}
} // namespace

QVariantList toVariant(const SourceMap& m) { return {m.a, m.b, m.c, m.d, m.e, m.f}; }

SourceMap sourceMapFrom(const QVariant& value) {
    const auto list = value.toList();
    if (list.size() != 6) return {};
    double v[6];
    for (int i = 0; i < 6; ++i) {
        bool ok = false;
        v[i] = list[i].toDouble(&ok);
        if (!ok || !std::isfinite(v[i])) return {};
    }
    return {v[0], v[1], v[2], v[3], v[4], v[5]};
}

Params paramsFrom(const QVariantMap& map, QString* error) {
    try {
        QStringList ignored;
        return fromJson(QJsonObject::fromVariantMap(map), &ignored);
    } catch (const std::exception& e) {
        if (error) *error = QString::fromUtf8(e.what());
        return {};
    }
}

std::optional<Grade> gradeFor(const Params& params, const QColorSpace& space) {
    const auto midGrey = midGreyFor(space.isValid() ? space : QColorSpace(QColorSpace::SRgb));
    if (!midGrey) return std::nullopt;
    Grade grade(params, *midGrey);
    if (grade.isIdentity()) return std::nullopt;
    return grade;
}

void gradeImage(QImage& image, const Grade& grade, const SourceMap& map, int threads) {
    enum class Kind { half, single, u16 } kind;
    switch (image.format()) {
    case QImage::Format_RGBX16FPx4: case QImage::Format_RGBA16FPx4: kind = Kind::half; break;
    case QImage::Format_RGBX32FPx4: case QImage::Format_RGBA32FPx4: kind = Kind::single; break;
    case QImage::Format_RGBX64: case QImage::Format_RGBA64: kind = Kind::u16; break;
    default: throw std::invalid_argument("Post-Dev cannot grade this displayed image's format");
    }
    if (grade.isIdentity() || image.isNull()) return;
    const int width = image.width(), height = image.height();
    const double fw = width, fh = height;
    uchar* bits = image.bits();
    const qsizetype stride = image.bytesPerLine();
    forRows(height, threads, [&](int y) {
        uchar* line = bits + qsizetype(y) * stride;
        const double v = (y + 0.5) / fh;
        for (int x = 0; x < width; ++x) {
            const auto [su, sv] = map((x + 0.5) / fw, v);
            switch (kind) {
            case Kind::half: {
                auto* p = reinterpret_cast<QRgbaFloat16*>(line) + x;
                const auto out = grade.pixel({float(p->red()), float(p->green()), float(p->blue())}, float(su), float(sv));
                p->setRed(qfloat16(out[0]));
                p->setGreen(qfloat16(out[1]));
                p->setBlue(qfloat16(out[2]));
                break;
            }
            case Kind::single: {
                auto* p = reinterpret_cast<float*>(line) + 4 * x;
                const auto out = grade.pixel({p[0], p[1], p[2]}, float(su), float(sv));
                p[0] = out[0];
                p[1] = out[1];
                p[2] = out[2];
                break;
            }
            case Kind::u16: {
                auto* p = reinterpret_cast<quint16*>(line) + 4 * x;
                const auto out = grade.pixel({p[0] / 65535.0f, p[1] / 65535.0f, p[2] / 65535.0f}, float(su), float(sv));
                for (int i = 0; i < 3; ++i) p[i] = quint16(out[i] * 65535.0f + 0.5f);
                break;
            }
            }
        }
    });
}

} // namespace spk::desktop::postdev
