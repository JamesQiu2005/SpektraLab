#include "DisplayColor.hpp"
#include <QColorSpace>
#include <cstdio>
#include <stdexcept>

namespace {
void check(bool ok,const char* message) { if(!ok)throw std::runtime_error(message); }
}

int main() {
    try {
        QImage source(2,1,QImage::Format_RGB32);
        source.setColorSpace(QColorSpace(QColorSpace::SRgb));
        source.setPixelColor(0,0,QColor(64,128,192));
        source.setPixelColor(1,0,QColor(220,90,30));
        const auto original=source;
        const QColorSpace monitor(QColorSpace::AdobeRgb);
        const auto converted=display::transformToMonitorProfile(source,monitor.iccProfile());
        check(!converted.isNull(),"valid monitor profile was rejected");
        check(converted.colorSpace()==monitor,"converted preview is not tagged with monitor profile");
        check(converted.pixelColor(0,0)!=source.pixelColor(0,0),"monitor transform left encoded samples unchanged");
        check(source==original,"monitor transform mutated the sRGB source image");
        check(display::transformToMonitorProfile(source,QByteArray("invalid ICC" )).isNull(),
              "invalid monitor profile was accepted");
        std::puts("PASS synthetic monitor ICC transform, source preservation, invalid profile rejection");
        return 0;
    } catch(const std::exception& e) { std::fprintf(stderr,"FAIL %s\n",e.what()); return 1; }
}
