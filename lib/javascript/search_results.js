// JavaScript code for extracting prices from TCGPlayer search results
function searchResults(params) {
  const cardName = params.cardName;
  console.log('Searching for card:', cardName);
  
  function extractNumericPrice(priceText) {
    if (!priceText) {
      console.log('No price text provided');
      return null;
    }
    
    console.log('Processing price text:', {
      original: priceText,
      cleaned: priceText.replace(/[^\d.]/g, ''),
      hasDollarSign: priceText.includes('$'),
      length: priceText.length
    });
    
    // Updated regex to handle prices with commas
    const priceRegex = /\$[\d,]+\.\d{2}/;
    
    // Test if the price matches the pattern
    const matches = priceRegex.test(priceText);
    console.log('Price regex test:', {
      matches,
      pattern: priceRegex.toString(),
      testResult: matches ? 'matched' : 'no match',
      input: priceText
    });
    
    if (!matches) {
      console.log('No price pattern found in:', priceText);
      return null;
    }
    
    // Extract just the numeric part (remove $ and commas)
    const numericStr = priceText.replace(/[^\d.]/g, '');
    const result = parseFloat(numericStr);
    console.log('Price extraction result:', {
      numericStr,
      parsedResult: result,
      isNaN: isNaN(result),
      originalText: priceText,
      cleanedText: numericStr,
      validation: {
        isPositive: result > 0,
        isFinite: isFinite(result),
        isValid: result > 0 && isFinite(result)
      }
    });
    
    // Only return if we have a valid positive number
    if (isNaN(result) || !isFinite(result) || result <= 0) {
      console.log('Invalid price value:', result);
      return null;
    }
    
    return result;
  }

  function isExactCardMatch(title, cardName) {
    if (!title || !cardName) {
      console.log('Missing title or cardName:', { title, cardName });
      return false;
    }
    
    // Log the exact strings we're comparing
    console.log('\n=== CARD MATCH VALIDATION ===');
    console.log('Original title:', title);
    console.log('Original cardName:', cardName);
    
    // Normalize both strings - more aggressive normalization
    const normalize = (str) => {
      const normalized = String(str)
        .toLowerCase()
        .trim()
        .replace(/\s+/g, ' ')  // normalize whitespace
        .replace(/[^a-z0-9\s]/g, '') // remove all non-alphanumeric chars except spaces
        .replace(/\s+/g, ' '); // normalize whitespace again
      console.log('Normalized string:', normalized);
      return normalized;
    };
    
    const normalizedTitle = normalize(title);
    const normalizedCardName = normalize(cardName);
    
    console.log('\nNormalized comparison:');
    console.log('Normalized title:', normalizedTitle);
    console.log('Normalized cardName:', normalizedCardName);
    console.log('Exact match after normalization:', normalizedTitle === normalizedCardName);
    
    // Simple exact match after normalization
    if (normalizedTitle === normalizedCardName) {
      console.log('Found exact match after normalization');
      return true;
    }
    
    // Try partial match as fallback
    const titleWords = normalizedTitle.split(/\s+/);
    const cardNameWords = normalizedCardName.split(/\s+/);
    
    console.log('\nWord-by-word comparison:');
    console.log('Title words:', titleWords);
    console.log('Card name words:', cardNameWords);
    
    // Check if all words from cardName are present in title
    const wordMatches = cardNameWords.map(word => {
      const matches = titleWords.some(titleWord => 
        titleWord.includes(word) || word.includes(titleWord)
      );
      console.log(`Word "${word}" matches:`, matches);
      return matches;
    });
    
    const allWordsMatch = wordMatches.every(match => match);
    console.log('All words match:', allWordsMatch);
    
    // Additional check for "The" prefix
    const hasThePrefix = normalizedCardName.startsWith('the ') && 
                        normalizedTitle.startsWith('the ');
    const matchesWithoutThe = !hasThePrefix && 
                             (normalizedTitle.replace(/^the\s+/, '') === normalizedCardName.replace(/^the\s+/, ''));
    
    console.log('\n"The" prefix check:');
    console.log('Has "The" prefix:', hasThePrefix);
    console.log('Matches without "The":', matchesWithoutThe);
    if (matchesWithoutThe) {
      console.log('Title without "The":', normalizedTitle.replace(/^the\s+/, ''));
      console.log('Card name without "The":', normalizedCardName.replace(/^the\s+/, ''));
    }
    
    const finalResult = allWordsMatch || matchesWithoutThe;
    console.log('\nFinal match result:', finalResult);
    console.log('=====================\n');
    
    return finalResult;
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

    // Log the search target at the start
    console.log('\n=== SEARCH TARGET ===');
    console.log('Card name to find:', cardName);
    console.log('===================\n');

    // Process each product card
    const validProducts = productCards.map((card, index) => {
      console.log(`\n=== Processing card ${index + 1} ===`);
      
      // Get elements using multiple possible selectors
      const titleElement = card.querySelector('.product-card__title') || 
                         card.querySelector('[class*="title"]') ||
                         card.querySelector('[class*="name"]');
      const priceElement = card.querySelector('.inventory__price-with-shipping') || 
                         card.querySelector('.product-card__market-price--value') ||
                         card.querySelector('[class*="price"]');
      const linkElement = card.querySelector('a[href*="/product/"]') || 
                        card.closest('a[href*="/product/"]');

      // Add detailed logging for price element selection
      console.log('\nPrice element selection:');
      console.log('- Direct selector (.inventory__price-with-shipping):', card.querySelector('.inventory__price-with-shipping')?.outerHTML);
      console.log('- Market price selector (.product-card__market-price--value):', card.querySelector('.product-card__market-price--value')?.outerHTML);
      console.log('- Generic price selector ([class*="price"]):', card.querySelector('[class*="price"]')?.outerHTML);
      console.log('- Selected price element:', priceElement?.outerHTML);
      console.log('- All price elements in card:', Array.from(card.querySelectorAll('[class*="price"]')).map(el => ({
        class: el.className,
        text: el.textContent,
        html: el.outerHTML
      })));

      // Log the full card HTML for debugging
      console.log('Full card HTML:', card.outerHTML);

      // Log detailed element info
      console.log('\nElement details:');
      if (titleElement) {
        console.log('Title element found:');
        console.log('- Class:', titleElement.className);
        console.log('- Text content:', titleElement.textContent);
        console.log('- Inner text:', titleElement.innerText);
        console.log('- Inner HTML:', titleElement.innerHTML);
        console.log('- Full element HTML:', titleElement.outerHTML);
      } else {
        console.log('Title element NOT found');
      }

      if (priceElement) {
        console.log('\nPrice element found:');
        console.log('- Class:', priceElement.className);
        console.log('- Text content:', priceElement.textContent);
        console.log('- Inner text:', priceElement.innerText);
        console.log('- Inner HTML:', priceElement.innerHTML);
        console.log('- Full element HTML:', priceElement.outerHTML);
        if (priceElement.parentElement) {
          console.log('- Parent HTML:', priceElement.parentElement.outerHTML);
        }
      } else {
        console.log('\nPrice element NOT found');
      }

      if (!titleElement || !priceElement) {
        console.log('\nMissing required elements:', {
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
      
      // Add detailed price text extraction logging
      console.log('\nPrice text extraction:');
      console.log('- Raw price element:', {
        textContent: priceElement.textContent,
        innerText: priceElement.innerText,
        innerHTML: priceElement.innerHTML,
        outerHTML: priceElement.outerHTML
      });
      console.log('- Extracted price text:', {
        text: priceText,
        length: priceText.length,
        hasDollarSign: priceText.includes('$'),
        hasComma: priceText.includes(','),
        elementType: priceElement.tagName
      });

      if (!title || !priceText) {
        console.log('\nEmpty text content:', {
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
        console.log('\nSkipping non-playable card:', title);
        return null;
      }

      const isMatch = isExactCardMatch(title, cardName);
      const hasValidPrice = !isNaN(price) && price > 0;
      
      // Add detailed validation logging
      console.log('\n=== VALIDATION CHECK ===');
      console.log('1. Card Name Validation:');
      console.log('   - Title found:', title);
      console.log('   - Card name to match:', cardName);
      console.log('   - Is match:', isMatch);
      console.log('   - Normalized title:', title.toLowerCase().trim().replace(/[^a-z0-9\s]/g, ''));
      console.log('   - Normalized cardName:', cardName.toLowerCase().trim().replace(/[^a-z0-9\s]/g, ''));
      
      console.log('\n2. Price Validation:');
      console.log('   - Price found:', price);
      console.log('   - Price type:', typeof price);
      console.log('   - Is NaN:', isNaN(price));
      console.log('   - Is positive:', price > 0);
      console.log('   - Has valid price:', hasValidPrice);
      console.log('   - Raw price text:', priceText);
      
      console.log('\n3. Final Validation:');
      console.log('   - Both valid:', isMatch && hasValidPrice);
      console.log('   - Failing check:', !isMatch ? 'card name' : 'price');
      console.log('   - Validation details:', {
        cardNameMatch: isMatch,
        priceValid: hasValidPrice,
        priceValue: price,
        priceText: priceText,
        title: title,
        cardName: cardName
      });
      console.log('=====================\n');
      
      if (isMatch && hasValidPrice) {
        console.log('\nFound valid product:', { 
          title, 
          price, 
          url,
          isMatch,
          hasValidPrice
        });
        return { title, price, url };
      } else {
        console.log('\nInvalid product:', { 
          title, 
          price, 
          isMatch,
          hasValidPrice,
          reason: !isMatch ? 'title does not match' : 'invalid price',
          details: {
            cardNameMatch: isMatch,
            priceValid: hasValidPrice,
            priceValue: price,
            priceText: priceText,
            title: title,
            cardName: cardName
          }
        });
        return null;
      }
    }).filter(Boolean);

    console.log('\n=== FINAL RESULTS ===');
    console.log('Total cards processed:', productCards.length);
    console.log('Valid products found:', validProducts.length);
    if (validProducts.length === 0) {
      console.log('No valid products found - validation failed at:');
      productCards.forEach((card, index) => {
        const title = card.querySelector('.product-card__title')?.textContent.trim();
        const price = card.querySelector('.inventory__price-with-shipping')?.textContent.trim();
        console.log(`Card ${index + 1}:`);
        console.log('  - Title:', title);
        console.log('  - Price:', price);
        console.log('  - Raw HTML:', card.outerHTML);
      });
    }
    console.log('=====================\n');

    // Sort by price and return the lowest priced product
    validProducts.sort((a, b) => a.price - b.price);
    const lowest = validProducts[0];
    console.log('Selected lowest priced product:', lowest);
    return lowest;
  }

  // Execute the async function
  return processCards();
} 