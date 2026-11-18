#include "pdf_native_bridge.h"
#include <fpdfview.h>
#include <fpdf_edit.h>
#include <fpdf_save.h>
#include <fpdf_text.h>
#include <fpdf_annot.h>
#include <fpdf_transformpage.h>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFJob.hh>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <type_traits>
#include <mutex>
#include <string>
#include <vector>
#include <functional>
#include <stdexcept>
#include <set>
static_assert(offsetof(PdfRect,x0)==8,"Dart/native rectangle ABI mismatch");

namespace {
std::once_flag initialized;
std::mutex pdf_mutex;
thread_local int32_t last_error = 0;
struct DocumentDelete { void operator()(FPDF_DOCUMENT p) const { if(p) FPDF_CloseDocument(p); } };
struct PageDelete { void operator()(FPDF_PAGE p) const { if(p) FPDF_ClosePage(p); } };
struct BitmapDelete { void operator()(FPDF_BITMAP p) const { if(p) FPDFBitmap_Destroy(p); } };
struct TextDelete { void operator()(FPDF_TEXTPAGE p) const { if(p) FPDFText_ClosePage(p); } };
using Document = std::unique_ptr<std::remove_pointer_t<FPDF_DOCUMENT>, DocumentDelete>;
using Page = std::unique_ptr<std::remove_pointer_t<FPDF_PAGE>, PageDelete>;
using Bitmap = std::unique_ptr<std::remove_pointer_t<FPDF_BITMAP>, BitmapDelete>;
struct Writer : FPDF_FILEWRITE {
    std::FILE* file;
    explicit Writer(std::FILE* f): file(f) { version=1; WriteBlock=&write; }
    static int write(FPDF_FILEWRITE* base, const void* data, unsigned long size) {
        return std::fwrite(data,1,size,static_cast<Writer*>(base)->file)==size;
    }
};
bool save(FPDF_DOCUMENT doc, const char* output) {
    std::unique_ptr<std::FILE, decltype(&std::fclose)> file(std::fopen(output,"wb"), &std::fclose);
    if(!file) return false;
    Writer writer(file.get());
    return FPDF_SaveAsCopy(doc,&writer,FPDF_NO_INCREMENTAL)!=0;
}
void init() { std::call_once(initialized, [] { FPDF_InitLibrary(); }); }
bool valid_index(FPDF_DOCUMENT doc,int index) { return doc && index>=0 && index<FPDF_GetPageCount(doc); }
FS_POINTF normalized_point(FPDF_PAGE page,double x,double y) {
    double px=0,py=0;
    if(!FPDF_DeviceToPage(page,0,0,100000,100000,0,static_cast<int>(std::round(x*100000)),static_cast<int>(std::round(y*100000)),&px,&py))
        throw std::runtime_error("Page coordinate conversion failed");
    return {static_cast<float>(px),static_cast<float>(py)};
}
void utf8(std::string& out, unsigned int c) {
    if(c<0x80) out.push_back(static_cast<char>(c));
    else if(c<0x800) { out.push_back(static_cast<char>(0xc0|(c>>6))); out.push_back(static_cast<char>(0x80|(c&63))); }
    else if(c<0x10000) { out.push_back(static_cast<char>(0xe0|(c>>12))); out.push_back(static_cast<char>(0x80|((c>>6)&63))); out.push_back(static_cast<char>(0x80|(c&63))); }
    else { out.push_back(static_cast<char>(0xf0|(c>>18))); out.push_back(static_cast<char>(0x80|((c>>12)&63))); out.push_back(static_cast<char>(0x80|((c>>6)&63))); out.push_back(static_cast<char>(0x80|(c&63))); }
}
}
void* pdf_open(const char* path,const char* password) {
    std::lock_guard<std::mutex> guard(pdf_mutex); init(); last_error=0;
    if(!path) {last_error=1; return nullptr;}
    auto doc=FPDF_LoadDocument(path,password ? password : "");
    if(!doc) last_error=2;
    return doc;
}
void pdf_close(void* handle) {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);std::lock_guard<std::mutex> guard(pdf_mutex); if(doc) FPDF_CloseDocument(doc);}
int32_t pdf_page_count(void* handle) {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);std::lock_guard<std::mutex> guard(pdf_mutex); return doc ? FPDF_GetPageCount(doc) : -1;}
int32_t pdf_page_size(void* handle,int32_t index,double* width,double* height) {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!valid_index(doc,index)||!width||!height) return 0;
    Page page(FPDF_LoadPage(doc,index)); if(!page) return 0;
    *width=FPDF_GetPageWidth(page.get()); *height=FPDF_GetPageHeight(page.get()); return 1;
}
uint8_t* pdf_render(void* handle,int32_t index,int32_t max_edge,int32_t* width,int32_t* height,size_t* size) {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex); last_error=0;
    if(!valid_index(doc,index)||!width||!height||!size||max_edge<64||max_edge>20000) {last_error=1;return nullptr;}
    Page page(FPDF_LoadPage(doc,index)); if(!page) {last_error=2;return nullptr;}
    const double w=FPDF_GetPageWidth(page.get()),h=FPDF_GetPageHeight(page.get());
    if(!std::isfinite(w)||!std::isfinite(h)||w<=0||h<=0) return nullptr;
    double scale=static_cast<double>(max_edge)/std::max(w,h);
    *width=std::max(1,static_cast<int>(std::ceil(w*scale))); *height=std::max(1,static_cast<int>(std::ceil(h*scale)));
    *size=static_cast<size_t>(*width)*static_cast<size_t>(*height)*4;
    if(*size>180000000) {last_error=1;return nullptr;}
    Bitmap bitmap(FPDFBitmap_Create(*width,*height,1)); if(!bitmap) return nullptr;
    FPDFBitmap_FillRect(bitmap.get(),0,0,*width,*height,0xffffffff);
    FPDF_RenderPageBitmap(bitmap.get(),page.get(),0,0,*width,*height,0,FPDF_ANNOT);
    auto* pixels=static_cast<uint8_t*>(std::malloc(*size)); if(!pixels) return nullptr;
    const auto* source=static_cast<const uint8_t*>(FPDFBitmap_GetBuffer(bitmap.get()));
    int stride=FPDFBitmap_GetStride(bitmap.get());
    for(int y=0;y<*height;++y) for(int x=0;x<*width;++x) {
        size_t d=(static_cast<size_t>(y)*(*width)+x)*4; int s=y*stride+x*4;
        pixels[d]=source[s+2];pixels[d+1]=source[s+1];pixels[d+2]=source[s];pixels[d+3]=source[s+3];
    }
    return pixels;
}
char* pdf_text(void* handle,int32_t index) {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!valid_index(doc,index)) return nullptr;
    Page page(FPDF_LoadPage(doc,index)); if(!page) return nullptr;
    std::unique_ptr<std::remove_pointer_t<FPDF_TEXTPAGE>, TextDelete> text(FPDFText_LoadPage(page.get())); if(!text) return nullptr;
    int count=FPDFText_CountChars(text.get()); if(count<0 || count>2000000) return nullptr;
    std::string out; out.reserve(static_cast<size_t>(count)*2);
    for(int i=0;i<count;++i) {unsigned int c=FPDFText_GetUnicode(text.get(),i);if(c && c<=0x10ffff && !(c>=0xd800 && c<=0xdfff)) utf8(out,c);}
    auto* result=static_cast<char*>(std::malloc(out.size()+1)); if(result) std::memcpy(result,out.c_str(),out.size()+1);
    return result;
}
int32_t pdf_qpdf_job(const char* job_json) {
    std::lock_guard<std::mutex> guard(pdf_mutex); last_error=0;
    if(!job_json) return 0;
    try {QPDFJob job; job.initializeFromJson(job_json);job.run();return 1;}
    catch(const std::exception&) {last_error=3;return 0;}
}
int32_t pdf_blank(const char* output,double width,double height) {
    std::lock_guard<std::mutex> guard(pdf_mutex); init();
    if(!output||!std::isfinite(width)||!std::isfinite(height)||width<=0||height<=0||width>2880||height>2880) return 0;
    Document doc(FPDF_CreateNewDocument()); if(!doc) return 0;
    Page page(FPDFPage_New(doc.get(),0,width,height)); if(!page) return 0;
    if(!FPDFPage_GenerateContent(page.get())) return 0;
    return save(doc.get(),output) ? 1 : 0;
}
int32_t pdf_redact(void* handle,const char* output,const PdfRect* boxes,int32_t count,int32_t dpi) {
    auto document = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!document||!output||count<0||count>10000||(count>0&&!boxes)||(dpi!=72&&dpi!=150&&dpi!=300)) return 0;
    for(int i=0;i<count;++i) {
        const auto& r=boxes[i];
        if(!valid_index(document,r.page)||!std::isfinite(r.x0)||!std::isfinite(r.y0)||!std::isfinite(r.x1)||!std::isfinite(r.y1)||
           r.x0<0||r.y0<0||r.x1>1||r.y1>1||r.x0>=r.x1||r.y0>=r.y1) return 0;
    }
    Document target(FPDF_CreateNewDocument()); if(!target) return 0;
    int pages=FPDF_GetPageCount(document);
    for(int index=0;index<pages;++index) {
        Page original(FPDF_LoadPage(document,index)); if(!original) return 0;
        double w=FPDF_GetPageWidth(original.get()), h=FPDF_GetPageHeight(original.get());
        if(!std::isfinite(w)||!std::isfinite(h)||w<=0||h<=0||w*h*(dpi/72.0)*(dpi/72.0)>45000000) return 0;
        int width=static_cast<int>(std::ceil(w*dpi/72.0)),height=static_cast<int>(std::ceil(h*dpi/72.0));
        Bitmap bitmap(FPDFBitmap_Create(width,height,1)); if(!bitmap) return 0;
        FPDFBitmap_FillRect(bitmap.get(),0,0,width,height,0xffffffff);
        FPDF_RenderPageBitmap(bitmap.get(),original.get(),0,0,width,height,0,FPDF_ANNOT);
        for(int b=0;b<count;++b) if(boxes[b].page==index) {
            const auto& r=boxes[b];int x=static_cast<int>(std::floor(r.x0*width)),y=static_cast<int>(std::floor(r.y0*height));
            FPDFBitmap_FillRect(bitmap.get(),x,y,static_cast<int>(std::ceil(r.x1*width))-x,static_cast<int>(std::ceil(r.y1*height))-y,0xff000000);
        }
        Page page(FPDFPage_New(target.get(),index,w,h)); if(!page) return 0;
        auto object=FPDFPageObj_NewImageObj(target.get()); if(!object) return 0;
        if(!FPDFImageObj_SetBitmap(nullptr,0,object,bitmap.get())) {FPDFPageObj_Destroy(object);return 0;}
        FPDFPageObj_Transform(object,w,0,0,h,0,0);
        FPDFPage_InsertObject(page.get(),object); // page owns object from this point
        if(!FPDFPage_GenerateContent(page.get())) return 0;
    }
    return save(target.get(),output) ? 1 : 0;
}
void pdf_free(void* memory) {std::free(memory);}
int32_t pdf_last_error(void) {return last_error;}

namespace {
std::string json_string(std::string const& input) {
    std::string out="\"";
    const char* hex="0123456789abcdef";
    for(unsigned char c: input) {
        if(c=='"'||c=='\\') {out+='\\';out+=static_cast<char>(c);}
        else if(c<32) {out+="\\u00";out+=hex[c>>4];out+=hex[c&15];}
        else out+=static_cast<char>(c);
    }
    return out+'"';
}
bool valid_box(PdfRect const& b) {
    return std::isfinite(b.x0)&&std::isfinite(b.y0)&&std::isfinite(b.x1)&&std::isfinite(b.y1)&&
      b.x0>=0&&b.y0>=0&&b.x1<=1&&b.y1<=1&&b.x0<b.x1&&b.y0<b.y1;
}
void visit_fields(QPDFObjectHandle array, std::string prefix,
    std::function<void(QPDFObjectHandle,std::string)> const& visitor, int depth=0) {
    if(depth>32) throw std::runtime_error("Field nesting limit");
    if(!array.isArray()) return;
    for(auto field: array.getArrayAsVector()) {
        auto title=field.getKey("/T");
        std::string name=prefix;
        if(title.isString()) {if(!name.empty()) name+='.';name+=title.getUTF8Value();}
        if(title.isString()) visitor(field,name);
        visit_fields(field.getKey("/Kids"),name,visitor,depth+1);
    }
}
}
int32_t pdf_scrub(const char* input,const char* output) {
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!input||!output) return 0;
    try {
        QPDF pdf;pdf.setSuppressWarnings(true);pdf.processFile(input);
        pdf.getTrailer().removeKey("/Info");
        auto root=pdf.getRoot();
        for(auto key: {"/Metadata","/OpenAction","/AA","/AF"}) root.removeKey(key);
        auto names=root.getKey("/Names");
        if(names.isDictionary()) {names.removeKey("/JavaScript");names.removeKey("/EmbeddedFiles");}
        for(auto page: QPDFPageDocumentHelper(pdf).getAllPages()) {
            auto obj=page.getObjectHandle();
            for(auto key: {"/Metadata","/Thumb","/AA","/PieceInfo"}) obj.removeKey(key);
        }
        QPDFWriter writer(pdf,output);writer.setObjectStreamMode(qpdf_o_generate);writer.write();return 1;
    } catch(std::exception const&) {last_error=3;return 0;}
}
int32_t pdf_crop(void* handle,const char* output,const PdfRect* boxes,int32_t count) try {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!doc||!output||!boxes||count<1||count>10000) return 0;
    for(int i=0;i<count;++i) if(!valid_box(boxes[i])||!valid_index(doc,boxes[i].page)) return 0;
    for(int i=0;i<count;++i) {
        Page page(FPDF_LoadPage(doc,boxes[i].page));if(!page) return 0;
        auto const& b=boxes[i];auto first=normalized_point(page.get(),b.x0,b.y0),last=normalized_point(page.get(),b.x1,b.y1);
        FPDFPage_SetCropBox(page.get(),std::min(first.x,last.x),std::min(first.y,last.y),std::max(first.x,last.x),std::max(first.y,last.y));
    }
    return save(doc,output)?1:0;
} catch(std::exception const&) {last_error=3;return 0;}
int32_t pdf_markup(void* handle,const char* output,const PdfRect* boxes,int32_t count,int32_t kind) try {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!doc||!output||!boxes||count<1||count>10000||(kind!=9&&kind!=10&&kind!=12)) return 0;
    for(int i=0;i<count;++i) if(!valid_box(boxes[i])||!valid_index(doc,boxes[i].page)) return 0;
    for(int i=0;i<count;++i) {
        Page page(FPDF_LoadPage(doc,boxes[i].page));if(!page) return 0;
        auto annot=FPDFPage_CreateAnnot(page.get(),kind);if(!annot) return 0;
        std::unique_ptr<std::remove_pointer_t<FPDF_ANNOTATION>,decltype(&FPDFPage_CloseAnnot)> handle(annot,&FPDFPage_CloseAnnot);
        auto const& b=boxes[i];auto tl=normalized_point(page.get(),b.x0,b.y0),tr=normalized_point(page.get(),b.x1,b.y0),
            bl=normalized_point(page.get(),b.x0,b.y1),br=normalized_point(page.get(),b.x1,b.y1);
        FS_RECTF rect{std::min(tl.x,br.x),std::max(tl.y,br.y),std::max(tl.x,br.x),std::min(tl.y,br.y)};
        FS_QUADPOINTSF quad{tl.x,tl.y,tr.x,tr.y,bl.x,bl.y,br.x,br.y};
        if(!FPDFAnnot_SetRect(annot,&rect)||!FPDFAnnot_AppendAttachmentPoints(annot,&quad)||
          !FPDFAnnot_SetColor(annot,FPDFANNOT_COLORTYPE_Color,kind==9?255:59,kind==9?232:73,kind==9?64:72,kind==9?100:255)) return 0;
        FPDFAnnot_SetFlags(annot,FPDF_ANNOT_FLAG_PRINT);
    }
    return save(doc,output)?1:0;
} catch(std::exception const&) {last_error=3;return 0;}
int32_t pdf_ink(void* handle,const char* output,int32_t index,const double* xy,int32_t points) try {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!valid_index(doc,index)||!output||!xy||points<2||points>50000) return 0;
    Page page(FPDF_LoadPage(doc,index));if(!page) return 0;
    std::vector<FS_POINTF> positions;positions.reserve(points);
    for(int i=0;i<points;++i) {
        double x=xy[i*2],y=xy[i*2+1];
        if(!std::isfinite(x)||!std::isfinite(y)||x<0||x>1||y<0||y>1) return 0;
        positions.push_back(normalized_point(page.get(),x,y));
    }
    auto annot=FPDFPage_CreateAnnot(page.get(),FPDF_ANNOT_INK);if(!annot) return 0;
    std::unique_ptr<std::remove_pointer_t<FPDF_ANNOTATION>,decltype(&FPDFPage_CloseAnnot)> annotation(annot,&FPDFPage_CloseAnnot);
    auto first=normalized_point(page.get(),0,0),last=normalized_point(page.get(),1,1);
    FS_RECTF rect{std::min(first.x,last.x),std::max(first.y,last.y),std::max(first.x,last.x),std::min(first.y,last.y)};
    if(!FPDFAnnot_SetRect(annot,&rect)||!FPDFAnnot_SetColor(annot,FPDFANNOT_COLORTYPE_Color,59,73,72,255)||
        FPDFAnnot_AddInkStroke(annot,positions.data(),positions.size())<0) return 0;
    FPDFAnnot_SetFlags(annot,FPDF_ANNOT_FLAG_PRINT);
    return save(doc,output)?1:0;
} catch(std::exception const&) {last_error=3;return 0;}
int32_t pdf_write_text(void* handle,const char* output,int32_t index,double x,double y,const uint16_t* text,double size,int32_t signature) try {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!valid_index(doc,index)||!output||!text||!std::isfinite(x)||!std::isfinite(y)||x<0||x>1||y<0||y>1||size<6||size>144) return 0;
    Page page(FPDF_LoadPage(doc,index));if(!page) return 0;
    auto object=FPDFPageObj_NewTextObj(doc,signature?"Times-Italic":"Helvetica",static_cast<float>(size));if(!object) return 0;
    if(!FPDFText_SetText(object,text)) {FPDFPageObj_Destroy(object);return 0;}
    const double width=FPDF_GetPageWidth(page.get()),height=FPDF_GetPageHeight(page.get());
    auto origin=normalized_point(page.get(),x,std::min(1.0,y+size/height));
    auto horizontal=normalized_point(page.get(),x+1/width,std::min(1.0,y+size/height));
    auto vertical=normalized_point(page.get(),x,std::min(1.0,y+size/height)-1/height);
    FPDFPageObj_Transform(object,horizontal.x-origin.x,horizontal.y-origin.y,vertical.x-origin.x,vertical.y-origin.y,origin.x,origin.y);
    FPDFPage_InsertObject(page.get(),object);
    if(!FPDFPage_GenerateContent(page.get())) return 0;
    return save(doc,output)?1:0;
} catch(std::exception const&) {last_error=3;return 0;}
char* pdf_form_fields(const char* input) {
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!input) return nullptr;
    try {
        QPDF pdf;pdf.setSuppressWarnings(true);pdf.processFile(input);std::string result="[";int count=0;
        visit_fields(pdf.getRoot().getKey("/AcroForm").getKey("/Fields"),"",[&](auto field,std::string name) {
            auto type=field.getKey("/FT");if(!type.isName()) return;
            if(++count>2000) throw std::runtime_error("Field limit");
            if(count>1) result+=',';
            auto value=field.getKey("/V");std::string text=value.isString()?value.getUTF8Value():value.isName()?value.getName():"";
            result+="{\"name\":"+json_string(name)+",\"type\":"+json_string(type.getName())+",\"value\":"+json_string(text)+",\"options\":[";
            auto options=field.getKey("/Opt");int n=0;
            if(options.isArray()) for(auto option:options.getArrayAsVector()) {
                if(option.isArray()&&option.getArrayNItems()>0) option=option.getArrayItem(0);
                if(option.isString()) {if(n++) result+=',';result+=json_string(option.getUTF8Value());}
            }
            if(type.isNameAndEquals("/Btn")) {
                std::set<std::string> states;
                auto collect=[&](QPDFObjectHandle widget) {auto normal=widget.getKey("/AP").getKey("/N");if(normal.isDictionary()) for(auto const& state:normal.getKeys()) states.insert(state);};
                collect(field);auto kids=field.getKey("/Kids");if(kids.isArray()) for(auto widget:kids.getArrayAsVector()) collect(widget);
                for(auto const& state:states) {if(n++) result+=',';result+=json_string(state);}
            }
            result+="]}";
        });
        result+=']';auto memory=static_cast<char*>(std::malloc(result.size()+1));
        if(memory) std::memcpy(memory,result.c_str(),result.size()+1);return memory;
    } catch(std::exception const&) {last_error=3;return nullptr;}
}
char* pdf_metadata(const char* input) {
    std::lock_guard<std::mutex> guard(pdf_mutex);if(!input) return nullptr;
    try {
        QPDF pdf;pdf.setSuppressWarnings(true);pdf.processFile(input);
        auto info=pdf.getTrailer().getKey("/Info");std::string result="{";bool first=true;
        if(info.isDictionary()) for(auto const& name:info.getKeys()) {
            auto value=info.getKey(name);if(!value.isString()) continue;
            if(!first) result+=',';first=false;
            result+=json_string(name.substr(1))+":"+json_string(value.getUTF8Value());
            if(result.size()>1048576) throw std::runtime_error("Metadata size limit");
        }
        if(!first) result+=',';
        result+="\"has_xmp\":"+std::string(pdf.getRoot().getKey("/Metadata").isStream()?"true":"false")+"}";
        auto memory=static_cast<char*>(std::malloc(result.size()+1));if(memory) std::memcpy(memory,result.c_str(),result.size()+1);return memory;
    } catch(std::exception const&) {last_error=3;return nullptr;}
}
int32_t pdf_fill_field(const char* input,const char* output,const char* name,const char* value) {
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!input||!output||!name||!value) return 0;
    try {
        QPDF pdf;pdf.setSuppressWarnings(true);pdf.processFile(input);bool found=false;
        auto acro=pdf.getRoot().getKey("/AcroForm");
        visit_fields(acro.getKey("/Fields"),"",[&](auto field,std::string title) {
            if(title!=name) return;
            auto type=field.getKey("/FT");
            if(type.isNameAndEquals("/Sig")) throw std::runtime_error("Digital signing requires a certificate");
            if(type.isNameAndEquals("/Btn")) {
                std::string state=value;if(state.empty()||state[0]!='/') state='/'+state;
                field.replaceKey("/V",QPDFObjectHandle::newName(state));
                auto kids=field.getKey("/Kids");
                bool supported=state=="/Off";
                auto update=[&](QPDFObjectHandle widget) {
                    auto appearance=widget.getKey("/AP").getKey("/N");
                    bool on=appearance.isDictionary()&&appearance.hasKey(state);
                    supported=supported||on;
                    widget.replaceKey("/AS",QPDFObjectHandle::newName(on?state:"/Off"));
                };
                if(kids.isArray()) {for(auto widget:kids.getArrayAsVector()) update(widget);}
                else update(field);
                if(!supported) throw std::runtime_error("Unknown button state");
            } else {
                field.replaceKey("/V",QPDFObjectHandle::newUnicodeString(value));
                field.removeKey("/AP");
            }
            found=true;
        });
        if(!found) return 0;
        acro.replaceKey("/NeedAppearances",QPDFObjectHandle::newBool(true));
        QPDFWriter writer(pdf,output);writer.write();return 1;
    } catch(std::exception const&) {last_error=3;return 0;}
}
uint8_t* pdf_render_tile(void* handle,int32_t index,int32_t fw,int32_t fh,int32_t x,int32_t y,int32_t w,int32_t h) {
    auto doc = static_cast<FPDF_DOCUMENT>(handle);
    std::lock_guard<std::mutex> guard(pdf_mutex);
    if(!valid_index(doc,index)||fw<1||fh<1||static_cast<int64_t>(fw)*fh>45000000||x<0||y<0||w<1||h<1||w>1024||h>1024||x>fw-w||y>fh-h) return nullptr;
    Page page(FPDF_LoadPage(doc,index));if(!page) return nullptr;
    Bitmap bitmap(FPDFBitmap_Create(w,h,1));if(!bitmap) return nullptr;
    FPDFBitmap_FillRect(bitmap.get(),0,0,w,h,0xffffffff);
    FPDF_RenderPageBitmap(bitmap.get(),page.get(),-x,-y,fw,fh,0,FPDF_ANNOT);
    auto memory=static_cast<uint8_t*>(std::malloc(static_cast<size_t>(w)*h*4));if(!memory) return nullptr;
    const auto source=static_cast<uint8_t*>(FPDFBitmap_GetBuffer(bitmap.get()));int stride=FPDFBitmap_GetStride(bitmap.get());
    for(int row=0;row<h;++row) for(int col=0;col<w;++col) {
        size_t d=(static_cast<size_t>(row)*w+col)*4;int s=row*stride+col*4;
        memory[d]=source[s+2];memory[d+1]=source[s+1];memory[d+2]=source[s];memory[d+3]=source[s+3];
    }
    return memory;
}
