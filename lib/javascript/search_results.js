// JavaScript code for extracting prices from TCGPlayer search results
function searchResults(params) {
  const cardName = params.cardName;
  console.log('Searching for card:', cardName);
  
  function extractNumericPrice(priceText) {
    if (!priceText) {
      console.log('No price text provided');
      return null;
    }
    
    // Create and inspect the regex object
    const priceRegex = /\$\d+\.\d{2}/;  // Simple match for $XX.XX
    
    // Test if the price matches the pattern
    if (!priceRegex.test(priceText)) {
      console.log('No price pattern found in:', priceText);
      return null;
    }
    
    // Extract just the numeric part (remove the $ sign)
    const numericStr = priceText.slice(1);
    const result = parseFloat(numericStr);
    console.log('Extracted numeric price:', result, 'from:', numericStr);
    return isNaN(result) ? null : result;
  }

  function isExactCardMatch(title, cardName) {
    if (!title || !cardName) {
      console.log('Missing title or cardName:', { title, cardName });
      return false;
    }
    
    // Normalize both strings
    const normalizedTitle = title.toLowerCase().trim().replace(/\s+/g, ' ');
    const normalizedCardName = String(cardName).toLowerCase().trim().replace(/\s+/g, ' ');
    
    console.log('Comparing card names:', {
      normalizedTitle,
      normalizedCardName,
      titleLength: normalizedTitle.length,
      cardNameLength: normalizedCardName.length
    });
    
    // First try exact match
    if (normalizedTitle === normalizedCardName) {
      console.log('Found exact match');
      return true;
    }
    
    // Then try match with punctuation delimiters
    const regex = new RegExp(
      `(^|\\s|[^a-zA-Z0-9])${normalizedCardName}(\\s|[^a-zA-Z0-9]|$)`,
      'i'
    );
    
    const isMatch = regex.test(normalizedTitle);
    console.log('Regex match result:', { 
      isMatch,
      matchIndex: normalizedTitle.search(regex),
      title: normalizedTitle
    });
    
    return isMatch;
  }

  // Wait for elements to be fully loaded
  function waitForElements() {
    return new Promise((resolve) => {
      let attempts = 0;
      const maxAttempts = 50; // 5 seconds total
      
      const checkElements = () => {
        attempts++;
        const cards = document.querySelectorAll('.product-card__product');
        console.log(`Attempt ${attempts}: Found ${cards.length} cards`);
        
        if (cards.length > 0) {
          // Check if any card has content
          const hasContent = Array.from(cards).some(card => {
            const title = card.querySelector('.product-card__title');
            const hasTitle = title && title.textContent.trim().length > 0;
            if (hasTitle) {
              console.log('Found card with title:', title.textContent.trim());
            }
            return hasTitle;
          });
          
          if (hasContent) {
            console.log('Found cards with content, waiting for stability...');
            // Give extra time for dynamic content to stabilize
            setTimeout(() => {
              console.log('Content should be stable now');
              resolve(true);
            }, 1000);
            return;
          }
        }
        
        if (attempts >= maxAttempts) {
          console.log('Max attempts reached, proceeding anyway');
          resolve(false);
          return;
        }
        
        console.log('Waiting for cards with content...');
        setTimeout(checkElements, 100);
      };
      
      checkElements();
    });
  }

  async function processCards() {
    // Wait for elements to be loaded
    const elementsLoaded = await waitForElements();
    if (!elementsLoaded) {
      console.log('Warning: Elements may not be fully loaded');
    }
    
    // Get all product cards
    const productCards = Array.from(document.querySelectorAll('.product-card__product'));
    console.log(`Found ${productCards.length} product cards`);

    // Process each product card
    const validProducts = productCards.map((card, index) => {
      console.log(`\nProcessing card ${index + 1}:`);
      
      // Get elements using multiple possible selectors
      const titleElement = card.querySelector('.product-card__title') || 
                         card.querySelector('[class*="title"]') ||
                         card.querySelector('[class*="name"]');
      const priceElement = card.querySelector('.inventory__price-with-shipping') || 
                         card.querySelector('[class*="price"]');
      const linkElement = card.querySelector('a[href*="/product/"]') || 
                        card.closest('a[href*="/product/"]');

      // Log detailed element info
      console.log('Element details:', {
        title: titleElement ? {
          exists: true,
          className: titleElement.className,
          textContent: titleElement.textContent,
          innerText: titleElement.innerText,
          innerHTML: titleElement.innerHTML,
          textLength: titleElement.textContent.length
        } : 'Not found',
        price: priceElement ? {
          exists: true,
          className: priceElement.className,
          textContent: priceElement.textContent,
          innerText: priceElement.innerText,
          innerHTML: priceElement.innerHTML,
          textLength: priceElement.textContent.length
        } : 'Not found',
        link: linkElement ? {
          exists: true,
          href: linkElement.href
        } : 'Not found'
      });

      if (!titleElement || !priceElement) {
        console.log('Missing required elements:', {
          hasTitle: !!titleElement,
          hasPrice: !!priceElement,
          hasLink: !!linkElement
        });
        return null;
      }

      // Get the text content with fallbacks
      const title = titleElement.textContent.trim() || 
                  titleElement.innerText.trim() || 
                  titleElement.innerHTML.trim();
      const priceText = priceElement.textContent.trim() || 
                      priceElement.innerText.trim() || 
                      priceElement.innerHTML.trim();
      
      console.log('Extracted text content:', {
        title,
        priceText,
        titleLength: title.length,
        priceTextLength: priceText.length,
        titleElementType: titleElement.tagName,
        priceElementType: priceElement.tagName
      });

      if (!title || !priceText) {
        console.log('Empty text content:', {
          titleEmpty: !title,
          priceTextEmpty: !priceText,
          titleElementHTML: titleElement.outerHTML,
          priceElementHTML: priceElement.outerHTML
        });
        return null;
      }

      const price = extractNumericPrice(priceText);
      const url = linkElement ? linkElement.href : null;

      // Skip art cards and proxies
      if (title.toLowerCase().includes('art card') || 
          title.toLowerCase().includes('proxy') ||
          title.toLowerCase().includes('playtest')) {
        console.log('Skipping non-playable card:', title);
        return null;
      }

      const isMatch = isExactCardMatch(title, cardName);
      const hasValidPrice = !isNaN(price) && price > 0;
      
      if (isMatch && hasValidPrice) {
        console.log('Found valid product:', { 
          title, 
          price, 
          url,
          isMatch,
          hasValidPrice
        });
        return { title, price, url };
      } else {
        console.log('Invalid product:', { 
          title, 
          price, 
          isMatch,
          hasValidPrice,
          reason: !isMatch ? 'title does not match' : 'invalid price'
        });
        return null;
      }
    }).filter(Boolean);

    console.log(`Found ${validProducts.length} valid products`);

    if (validProducts.length === 0) {
      console.log('No valid products found');
      return null;
    }

    // Sort by price and return the lowest priced product
    validProducts.sort((a, b) => a.price - b.price);
    const lowest = validProducts[0];
    console.log('Selected lowest priced product:', lowest);
    return lowest;
  }

  // Execute the async function
  return processCards();
} 