(() => {
  try {
    // Only run if we're in a browser environment
    if (typeof window === 'undefined' || typeof document === 'undefined') {
      console.log('Not in browser environment, skipping frame prevention');
      return;
    }

    // Store original methods safely
    const originalCreateElement = document.createElement;
    if (typeof originalCreateElement !== 'function') {
      console.log('document.createElement not available, skipping frame prevention');
      return;
    }

    // Override createElement
    document.createElement = function(tagName) {
      try {
        if (typeof tagName === 'string' && tagName.toLowerCase() === 'iframe') {
          console.log('Prevented iframe creation');
          return null;
        }
        return originalCreateElement.apply(this, arguments);
      } catch (e) {
        console.log('Error in createElement override:', e.message);
        return originalCreateElement.apply(this, arguments);
      }
    };

    // Block frame navigation
    try {
      window.addEventListener('beforeunload', (event) => {
        try {
          if (window !== window.top) {
            event.preventDefault();
            event.stopPropagation();
            return false;
          }
        } catch (e) {
          console.log('Error in beforeunload handler:', e.message);
        }
      }, true);
    } catch (e) {
      console.log('Error setting up beforeunload handler:', e.message);
    }

    // Block frame creation via innerHTML
    try {
      const originalInnerHTML = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
      if (originalInnerHTML && originalInnerHTML.set) {
        Object.defineProperty(Element.prototype, 'innerHTML', {
          set: function(value) {
            try {
              if (typeof value === 'string' && value.includes('<iframe')) {
                console.log('Prevented iframe creation via innerHTML');
                return;
              }
              originalInnerHTML.set.call(this, value);
            } catch (e) {
              console.log('Error in innerHTML setter:', e.message);
              originalInnerHTML.set.call(this, value);
            }
          },
          get: originalInnerHTML.get
        });
      }
    } catch (e) {
      console.log('Error setting up innerHTML protection:', e.message);
    }

    console.log('Frame prevention initialized successfully');
  } catch (e) {
    console.log('Error initializing frame prevention:', e.message);
  }
})(); 