#include "pdf_native_bridge.h"
#include <type_traits>
#include <iostream>
static_assert(sizeof(PdfRect)==40);
static_assert(offsetof(PdfRect,page)==0);
static_assert(offsetof(PdfRect,x0)==8);
static_assert(offsetof(PdfRect,y1)==32);
using Render = uint8_t* (*)(void*,int32_t,int32_t,int32_t*,int32_t*,size_t*);
using Markup = int32_t (*)(void*,const char*,const PdfRect*,int32_t,int32_t);
using Tile = uint8_t* (*)(void*,int32_t,int32_t,int32_t,int32_t,int32_t,int32_t,int32_t);
static_assert(std::is_same_v<decltype(&pdf_render),Render>);
static_assert(std::is_same_v<decltype(&pdf_markup),Markup>);
static_assert(std::is_same_v<decltype(&pdf_render_tile),Tile>);
int main(){std::cout<<"Native public-header ABI checks passed\n";return 0;}
