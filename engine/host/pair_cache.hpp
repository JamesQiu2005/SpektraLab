// Original PairComposer.Rendered policy: two holes and one spare, most recent
// first. Float RGB uses more bytes than Mac RGBAh, so also bound it to192 MiB.
// Worker-thread only; camera thumbnails and film simulation never enter here.
#pragma once
#include "pair_composer.hpp"
#include <vector>
namespace spkhost::pair {
class HoleCache {
    struct Entry { std::string source,key;Size native;Metadata metadata;FloatImage hole; };
    std::vector<Entry> entries;
    size_t kept_bytes=0;
    static size_t bytes(const FloatImage& image){return image.rgb.size()*sizeof(float);}
public:
    static constexpr size_t limit=192u*1024*1024,capacity=3;
    size_t size()const{return entries.size();}
    size_t memory()const{return kept_bytes;}
    bool source(const std::string& key,Source& into)const {
        if(key.empty())return false;
        for(const auto& entry:entries)if(entry.source==key) {
            into.pixels.width=entry.native.w;into.pixels.height=entry.native.h;into.metadata=entry.metadata;return true;
        }
        return false;
    }
    bool get(const std::string& key,FloatImage& into) {
        if(key.empty())return false;
        for(size_t i=0;i<entries.size();++i)if(entries[i].key==key) {
            into=entries[i].hole;
            std::rotate(entries.begin(),entries.begin()+i,entries.begin()+i+1);return true;
        }
        return false;
    }
    void keep(const std::string& source,const std::string& key,Size native,const Metadata& metadata,const FloatImage& hole) {
        const size_t amount=bytes(hole);if(source.empty()||key.empty()||amount>limit)return;
        for(auto i=entries.begin();i!=entries.end();) {
            if(i->key==key){kept_bytes-=bytes(i->hole);i=entries.erase(i);}else ++i;
        }
        while(!entries.empty()&&(entries.size()>=capacity||kept_bytes+amount>limit)) {
            kept_bytes-=bytes(entries.back().hole);entries.pop_back();
        }
        entries.insert(entries.begin(),Entry{source,key,native,metadata,hole});kept_bytes+=amount;
    }
};
} // namespace spkhost::pair
