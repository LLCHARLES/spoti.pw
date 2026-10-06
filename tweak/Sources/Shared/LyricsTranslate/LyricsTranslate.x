// Gemini translation starts listening for lyrics at launch (GeminiTranslate.h). The translations show
// only in the redesign's lyrics, so it runs there alone.
#import "Core/SGCore.h"
#import "GeminiTranslate.h"

void SGGeminiStart(void);

%ctor {
    if (!SGRedesignedUI()) return;
    dispatch_async(dispatch_get_main_queue(), ^{ SGGeminiStart(); });
}
