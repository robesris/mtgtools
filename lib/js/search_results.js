function searchResults(params) {
  const cardName = params.cardName;
  const condition = params.condition;

  async function processCards() {
    const elementsLoaded = await waitForElements();
    if (!elementsLoaded) {
      console.log('Warning: Elements may not be fully loaded');
    }
    
    // Get all search result elements
    const searchResults = Array.from(document.querySelectorAll('.search-result'));
    console.log(`Found ${searchResults.length} search results`);

    console.log('\n=== SEARCH TARGET ===');
    console.log('Card name to find:', cardName);
    console.log('Condition to filter:', condition);
    console.log('===================\n');

    const validProducts = searchResults.map((result, index) => {
      console.log(`\n=== Processing search result ${index + 1} ===`);
      
      // Get the product card within this search result
      const card = result.querySelector('.product-card__product');
      if (!card) {
        console.log('No product card found in search result');
        return null;
      }

      // Get elements from within this specific search result
      const titleElement = card.querySelector('.product-card__title');
      const priceElement = card.querySelector('.inventory__price-with-shipping');
      const conditionElement = card.querySelector('.product-card__condition') ||
                             card.closest('.search-result').querySelector('[class*="condition"]');
      // Get the link from the same search result element
      const linkElement = result.querySelector('a[href*="/product/"]');

      console.log('\nElement details:', {
        title: titleElement?.textContent?.trim(),
        price: priceElement?.textContent?.trim(),
        condition: conditionElement?.textContent?.trim(),
        link: linkElement?.href,
        searchResultHtml: result.outerHTML
      });

      if (!titleElement || !priceElement || !conditionElement || !linkElement) {
        console.log('Missing required elements:', {
          hasTitle: !!titleElement,
          hasPrice: !!priceElement,
          hasCondition: !!conditionElement,
          hasLink: !!linkElement
        });
        return null;
      }

      const title = titleElement.textContent.trim();
      const priceText = priceElement.textContent.trim();
      const cardCondition = conditionElement.textContent.trim().toLowerCase();
      
      if (cardCondition !== condition.toLowerCase()) {
        console.log('Condition mismatch:', {
          found: cardCondition,
          expected: condition.toLowerCase()
        });
        return null;
      }

      if (!title || !priceText) {
        console.log('Empty text content:', {
          titleEmpty: !title,
          priceTextEmpty: !priceText
        });
        return null;
      }

      const price = extractNumericPrice(priceText);
      const url = linkElement.href;

      // Skip art cards and proxies
      if (title.toLowerCase().includes('art card') || 
          title.toLowerCase().includes('proxy') ||
          title.toLowerCase().includes('playtest')) {
        console.log('Skipping non-playable card:', title);
        return null;
      }

      const isMatch = isExactCardMatch(title, cardName);
      const hasValidPrice = !isNaN(price) && price > 0;
      
      console.log('Card validation:', {
        title,
        cardName,
        isMatch,
        hasValidPrice,
        price,
        condition: cardCondition,
        url,
        searchResultHtml: result.outerHTML
      });
      
      if (isMatch && hasValidPrice) {
        return { 
          title, 
          price, 
          url, 
          condition: cardCondition,
          searchResultHtml: result.outerHTML // Include the full HTML for debugging
        };
      }
      return null;
    }).filter(Boolean);

    console.log('\n=== FINAL RESULTS ===');
    console.log('Total search results processed:', searchResults.length);
    console.log('Valid products found:', validProducts.length);
    
    if (validProducts.length === 0) {
      console.log('No valid products found');
      return null;
    }

    // Sort by price and get the lowest
    validProducts.sort((a, b) => a.price - b.price);
    const lowest = validProducts[0];
    console.log('Selected lowest priced product:', {
      ...lowest,
      searchResultHtml: lowest.searchResultHtml // Include the full HTML in the log
    });
    return lowest;
  }

  return processCards();
} 