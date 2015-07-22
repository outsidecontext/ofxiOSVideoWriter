#include "ofMain.h"
#include "ofAppiOSWindow.h"
#include "ofApp.h"

extern "C"{
    size_t fwrite$UNIX2003( const void *a, size_t b, size_t c, FILE *d )
    {
        return fwrite(a, b, c, d);
    }
    char* strerror$UNIX2003( int errnum )
    {
        return strerror(errnum);
    }
    time_t mktime$UNIX2003(struct tm * a)
    {
        return mktime(a);
    }
    double strtod$UNIX2003(const char * a, char ** b) {
        return strtod(a, b);
    }
}

int main(){
    
    ofAppiOSWindow * window = new ofAppiOSWindow();
    window->enableRendererES2();    // ofxiOSVideoWriter only works properly using ES2 renderer, because it needs shaders on iOS.
    window->enableDepthBuffer();
    window->enableRetina();
    
	ofSetupOpenGL(window, 1024, 768, OF_FULLSCREEN);
	ofRunApp(new ofApp);
}
