// Card search functionality for TCGPlayer
// Helper function to extract numeric price from text
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

// Helper function to check if a title matches the card name
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
async function waitForElements() {
  return new Promise((resolve) => {
    let attempts = 0;
    const maxAttempts = 100; // 10 seconds total
    let screenshotCount = 0;
    
    // Function to take a screenshot
    const takeScreenshot = () => {
      try {
        // Call the screenshot function that was injected by Ruby
        if (typeof window.takeDebugScreenshot === 'function') {
          window.takeDebugScreenshot(`search_wait_${screenshotCount}`);
          screenshotCount++;
        }
      } catch (e) {
        console.error('Error taking screenshot:', e);
      }
    };
    
    // Start screenshot interval
    const screenshotInterval = setInterval(takeScreenshot, 1000);
    
    const checkElements = () => {
      attempts++;
      // Use more specific selectors based on the actual HTML structure
      const cards = document.querySelectorAll('.product-card__product');
      console.log(`Attempt ${attempts}: Found ${cards.length} cards`);
      
      if (cards.length > 0) {
        // Check if any card has fully loaded content
        const hasContent = Array.from(cards).some(card => {
          const title = card.querySelector('.product-card__title');
          const price = card.querySelector('.inventory__price-with-shipping');
          const image = card.querySelector('.v-lazy-image-loaded');
          
          const hasTitle = title && title.textContent.trim().length > 0;
          const hasPrice = price && price.textContent.trim().length > 0;
          const hasImage = image && image.complete;
          
          if (hasTitle && hasPrice) {
            console.log('Found card with content:', {
              title: title.textContent.trim(),
              price: price.textContent.trim(),
              imageLoaded: hasImage
            });
          }
          
          // Require both title and price, but image is optional
          return hasTitle && hasPrice;
        });
        
        if (hasContent) {
          console.log('Found cards with content, waiting for stability...');
          // Give more time for dynamic content to stabilize
          setTimeout(() => {
            // Clear the screenshot interval
            clearInterval(screenshotInterval);
            
            // Double check that content is still there and stable
            const stableCards = document.querySelectorAll('.product-card__product');
            const stableContent = Array.from(stableCards).some(card => {
              const title = card.querySelector('.product-card__title');
              const price = card.querySelector('.inventory__price-with-shipping');
              return title && price && 
                     title.textContent.trim().length > 0 && 
                     price.textContent.trim().length > 0;
            });
            
            if (stableContent) {
              console.log('Content is stable, proceeding with search');
              resolve(true);
            } else {
              console.log('Content became unstable, continuing to wait...');
              setTimeout(checkElements, 100);
            }
          }, 5000); // Wait 5 seconds for stability
          return;
        }
      }
      
      if (attempts >= maxAttempts) {
        // Clear the screenshot interval
        clearInterval(screenshotInterval);
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

// Main card search function
async function cardSearch(params) {
  try {
    const cardName = JSON.parse(params).cardName;
    console.log('Searching for card:', cardName);
    
    // Log the entire page content for debugging
    console.log('Page content:', {
      title: document.title,
      url: window.location.href,
      bodyText: document.body.textContent.slice(0, 500) + '...' // First 500 chars
    });
    
    // Wait for elements to be loaded
    const elementsLoaded = await waitForElements();
    if (!elementsLoaded) {
      console.log('Warning: Elements may not be fully loaded');
    }
    
    // Get all product cards using the specific selector
    const productCards = Array.from(document.querySelectorAll('.product-card__product'));
    console.log(`Found ${productCards.length} product cards`);
    
    // Log all card titles found
    productCards.forEach((card, index) => {
      const title = card.querySelector('.product-card__title');
      const price = card.querySelector('.inventory__price-with-shipping');
      console.log(`Card ${index + 1}:`, {
        title: title ? title.textContent.trim() : 'No title',
        price: price ? price.textContent.trim() : 'No price',
        html: card.outerHTML.slice(0, 200) + '...' // First 200 chars of HTML
      });
    });

    // Process each product card
    const validProducts = productCards.map((card, index) => {
      console.log(`\nProcessing card ${index + 1}:`);
      
      // Get elements using specific selectors
      const titleElement = card.querySelector('.product-card__title');
      const priceElement = card.querySelector('.inventory__price-with-shipping');
      const linkElement = card.closest('a[href*="/product/"]');

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
      
      console.log('Card match details:', {
        title,
        cardName,
        isMatch,
        hasValidPrice,
        price,
        url,
        matchReason: !isMatch ? 'title does not match' : 'invalid price',
        normalizedTitle: title.toLowerCase().trim().replace(/\s+/g, ' '),
        normalizedCardName: String(cardName).toLowerCase().trim().replace(/\s+/g, ' ')
      });
      
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
      console.log('No valid products found. Summary of all cards processed:');
      productCards.forEach((card, index) => {
        const title = card.querySelector('.product-card__title')?.textContent.trim();
        const price = card.querySelector('.inventory__price-with-shipping')?.textContent.trim();
        console.log(`Card ${index + 1}:`, { title, price });
      });
      return null;
    }

    // Sort by price and return the lowest priced product
    validProducts.sort((a, b) => a.price - b.price);
    const lowest = validProducts[0];
    console.log('Selected lowest priced product:', lowest);
    return lowest;
  } catch (error) {
    console.error('Error in cardSearch:', error);
    console.error('Error stack:', error.stack);
    return null;
  }
}

// Export the cardSearch function
cardSearch
 