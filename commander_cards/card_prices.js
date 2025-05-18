async function updatePrices(cardName, cardElement) {
  const priceInfo = cardElement.querySelector('.price-info');
  priceInfo.innerHTML = '<span class="loading">Loading prices...</span>';
  
  try {
    // Convert card name to TCGPlayer format
    const tcgName = cardName.toLowerCase().replace(/[^a-z0-9\s-]/g, '').replace(/\s+/g, '-');
    const searchUrl = `https://www.tcgplayer.com/search/magic/product?q=${encodeURIComponent(tcgName)}`;
    
    // First get the search results page
    const searchResponse = await fetch(searchUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
      }
    });
    const searchHtml = await searchResponse.text();
    
    // Parse the HTML to find the first product card
    const parser = new DOMParser();
    const searchDoc = parser.parseFromString(searchHtml, 'text/html');
    const productCard = searchDoc.querySelector('.product-card');
    
    if (!productCard) {
      priceInfo.innerHTML = 'No prices found';
      return;
    }
    
    // Get the product URL
    const productUrl = productCard.querySelector('a').href;
    if (!productUrl) {
      priceInfo.innerHTML = 'No prices found';
      return;
    }
    
    // Get the product page
    const productResponse = await fetch(productUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
      }
    });
    const productHtml = await productResponse.text();
    const productDoc = parser.parseFromString(productHtml, 'text/html');
    
    // Find price rows for LP and NM
    const prices = {};
    productDoc.querySelectorAll('.price-point').forEach(pricePoint => {
      const condition = pricePoint.querySelector('.condition')?.textContent?.trim().toLowerCase();
      if (!['lightly played', 'near mint'].includes(condition)) return;
      
      const price = pricePoint.querySelector('.price')?.textContent?.trim();
      const shipping = pricePoint.querySelector('.shipping')?.textContent?.trim();
      let total = parseFloat(price.replace('$', ''));
      
      if (shipping && shipping.match(/\$[\d.]+/)) {
        total += parseFloat(shipping.match(/\$[\d.]+/)[0].replace('$', ''));
      }
      
      prices[condition] = {
        price: price,
        shipping: shipping,
        total: `$${total.toFixed(2)}`,
        url: productUrl
      };
    });
    
    // Update the price display
    let html = '';
    if (prices['near mint']) {
      const nm = prices['near mint'];
      html += `NM: <a href="${nm.url}" target="_blank">${nm.total}</a>`;
    }
    if (prices['lightly played']) {
      const lp = prices['lightly played'];
      if (html) html += ' | ';
      html += `LP: <a href="${lp.url}" target="_blank">${lp.total}</a>`;
    }
    priceInfo.innerHTML = html || 'No prices found';
    
    // Store in localStorage for caching
    const cacheData = {
      timestamp: Date.now(),
      prices: prices
    };
    localStorage.setItem(`price_${cardName}`, JSON.stringify(cacheData));
    
  } catch (error) {
    priceInfo.innerHTML = 'Error loading prices';
    console.error('Error:', error);
  }
}

function loadCachedPrices() {
  document.querySelectorAll('.card').forEach(card => {
    const cardName = card.querySelector('.card-name').textContent;
    const cachedData = localStorage.getItem(`price_${cardName}`);
    
    if (cachedData) {
      const data = JSON.parse(cachedData);
      // Only use cache if it's less than 24 hours old
      if (Date.now() - data.timestamp < 86400000) {
        const prices = data.prices;
        let html = '';
        if (prices['near mint']) {
          const nm = prices['near mint'];
          html += `NM: <a href="${nm.url}" target="_blank">${nm.total}</a>`;
        }
        if (prices['lightly played']) {
          const lp = prices['lightly played'];
          if (html) html += ' | ';
          html += `LP: <a href="${lp.url}" target="_blank">${lp.total}</a>`;
        }
        card.querySelector('.price-info').innerHTML = html || 'No prices found';
      }
    }
  });
}

document.addEventListener('DOMContentLoaded', function() {
  // Load cached prices on page load
  loadCachedPrices();
  
  // Add click handlers for price updates
  document.querySelectorAll('.card').forEach(card => {
    card.addEventListener('click', function() {
      const cardName = this.querySelector('.card-name').textContent;
      updatePrices(cardName, this);
    });
  });
}); 