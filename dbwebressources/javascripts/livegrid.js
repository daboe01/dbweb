// 26.1.2008 by daniel boehringer
// a rewrite of the original RicoLiveGrid, which did not work with prototype 1.6 any more.
// LiveGridScroller -----------------------------------------------------

LiveGridScroller = Class.create();
LiveGridScroller.prototype = {

	initialize: function(liveGrid, offset) {
		this.liveGrid = liveGrid;
		this.createScrollBar(offset);
		this.viewPort = liveGrid.viewPort;
		this.moveScroll(offset);
	},

	createScrollBar: function(offset) {
		var visibleHeight = (this.liveGrid.viewPort.visibleHeight());
		// create the outer div...
		this.scrollerDiv  = document.createElement("div");
		var scrollerStyle = this.scrollerDiv.style;
		scrollerStyle.borderRight= this.liveGrid.options.scrollerBorderRight;
		scrollerStyle.position	 = "absolute";
		scrollerStyle.left		 = (this.liveGrid.tableHeader.getWidth()+this.liveGrid.tableHeader.cumulativeOffset().left)+"px";
		scrollerStyle.width		 = "17px";
		scrollerStyle.height     = visibleHeight + "px";
		scrollerStyle.overflow	 = "auto";

		// create the inner div...
		this.heightDiv = document.createElement("div");
		this.heightDiv.style.width  = "1px";

		this.heightDiv.style.height = (Math.floor(visibleHeight * this.liveGrid.totalRows/this.liveGrid.pageSize) ) + "px" ;
		this.scrollerDiv.appendChild(this.heightDiv);
		this.scrollerDiv.onscroll = this.handleScroll.bindAsEventListener(this);


		var table = this.liveGrid.table;
		table.insert( {before: this.scrollerDiv} );

		Event.observe(table, Prototype.Browser.Gecko ? "DOMMouseScroll":"mousewheel", 
					function(evt) {
						if (evt.wheelDelta>=0 || evt.detail < 0) //wheel-up
								this.scrollerDiv.scrollTop -= (2*this.viewPort.rowHeight);
						else	this.scrollerDiv.scrollTop += (2*this.viewPort.rowHeight);
						this.handleScroll(null);
					}.bindAsEventListener(this), 
					false);
	  },

	moveScroll: function (rowOffset) {
		var pixelOffset=rowOffset*this.viewPort.rowHeight;
		this.scrollerDiv.scrollTop = pixelOffset;
	},

	handleScroll: function(e)
	{//	var vpOff = document.viewport.getScrollOffsets();
		this.viewPort.scrollToPixel(this.scrollerDiv.scrollTop);
		if ( this.liveGrid.options.onscroll ) this.liveGrid.options.onscroll( this.liveGrid, this.viewPort.topRow );
	}
};

// LiveGridDataChunk -------------------------------------------------

LiveGridDataChunk = Class.create();
LiveGridDataChunk.prototype = {
	initialize: function( offset, size, start, liveGrid ) {
		var ajaxOptions=Object.extend({}, liveGrid.ajaxOptions);
		this.liveGrid = liveGrid;
		this.offset =offset;	
		this.size = size;
		ajaxOptions.parameters = 'id='+liveGrid.tableId+'&page_size='+this.size+'&offset='+ this.offset +'&'+ liveGrid.options.request;
		ajaxOptions.onSuccess =  function(start, a)
		{	this.rows= eval("(" + a.responseText + ")");
			this.coalesceAndUpdate(start);
		}.bind(this, start);
		new Ajax.Request(liveGrid.uri, ajaxOptions);
	},
	coalesceAndUpdate: function( start ){
		var topVisibleRow = this.liveGrid.viewPort.topRow;
		var lastVisibleRow= topVisibleRow+this.liveGrid.pageSize;
		if (topVisibleRow  >= this.offset && topVisibleRow  <= this.offset+this.size||
			lastVisibleRow >= this.offset && lastVisibleRow <= this.offset+this.size)
		{	var first= Math.max(0,topVisibleRow-this.offset);
			var updateSkip=topVisibleRow<this.offset ? this.offset-topVisibleRow:0;
			var end= Math.min(first+this.liveGrid.pageSize-updateSkip, this.rows.length);
			if (end > first)
				this.liveGrid.viewPort._copyRows(this.rows.slice(first, end), updateSkip);
		}
		if(this.liveGrid.buffer._coalesce()) 
			setTimeout(this.coalesceAndUpdate.bind(this,start), 5);
	}
};

// LiveGridBuffer -----------------------------------------------------

LiveGridBuffer = Class.create();
LiveGridBuffer.prototype = {

	initialize: function(liveGrid) {
		this.liveGrid= liveGrid;
		this.chunks	  = new Array();
		this.chunkSize = this.liveGrid.bufferChunkSize;
		this.busy=0;
	},
	chunkContainingRange: function(offset, length) {
		var l= this.chunks.length;
		for(var i=0; i < l; i++) {
			var e= this.chunks[i];
			if(offset >= e.offset && offset+length<= e.offset+e.size )
				return e;
		}
		return undefined;
	},
	chunkIntersectingRange: function(offset, length) {
		var l= this.chunks.length;
		for (var i=0; i < l; i++) {
			var e= this.chunks[i];
			if (offset >= e.offset && offset <= e.offset+e.size ||
				offset+length>= e.offset && offset+length <= e.offset+e.size)
				return e;
		}
		return undefined;
	},
	_coalesce: function() {
		if(this.busy) return true;
		this.busy =1;
		var l= this.chunks.length-1;	// skip last
		for (var i=0; i < l; i++) {
			var e= this.chunks[i];
			var f= this.chunks[i+1];

			if(f.offset==e.offset+e.size)
			{	if(f.rows && e.rows)
				{	e.rows=e.rows.concat(f.rows);
					e.size+=f.size;
					this.chunks.splice(i+1,1);
					l--;
				} else
				{	this.busy=0;
					return true;
				}
			}
		}
		this.busy =0;
		return false;
	},
	insertChunk: function(chunk) {
		while(this.busy) {}
		this.busy =1;
		var l= this.chunks.length;
		if(!l)
		{	this.chunks.push(chunk);
			this.busy=0;
			return;
		}
		var i;
		for(i=0; i < l; i++)
		{	if(chunk.offset < this.chunks[i].offset) break;
		}
		this.chunks.splice(i,0,chunk);
		this.busy =0;
		this._coalesce();
	},
	getRows: function(start, count) {
		var  c;
//document.title=start+" "+count;
		if(!(c=this.chunkContainingRange(start, count)))
		{	var d;
			var page= parseInt(start/this.chunkSize);
			if(d=this.chunkIntersectingRange(start, count))
			{	if(start>d.offset) page++;
				else page=Math.max(page-1,0);
			}
			var fetchOffset=page* this.chunkSize;
			var fetchLength= this.chunkSize;
			// check whether new page is pending so coalescing has not taken place
			var  neighbour;
			if(!(neighbour=this.chunkContainingRange(fetchOffset, 1)))
			{	if(fetchOffset+fetchLength > this.liveGrid.totalRows)
					fetchLength= this.liveGrid.totalRows-fetchOffset;
				if(fetchLength>0)
				{	c=new LiveGridDataChunk(fetchOffset, fetchLength, start, this.liveGrid)
					this.insertChunk(c);
				}
			} else c=neighbour;
		}

		if(c && c.rows)
		{	var first= Math.max(0, start-c.offset)
			var end= Math.min(first+count, c.rows.length);
			if (end > first) return c.rows.slice(first, end);
		}
		else return new Array();
	}
};


//GridViewPort --------------------------------------------------

GridViewPort = Class.create();
GridViewPort.prototype = {

	initialize: function(liveGrid) {
		this.liveGrid = liveGrid;
		this.table = liveGrid.table
		this.buffer = liveGrid.buffer;

		this.rowHeight = (this.table.offsetHeight/liveGrid.pageSize);
		new Insertion.Before(this.table, "<div id='"+liveGrid.tableId+"_container'></div>");
		this.table.previousSibling.appendChild(this.table);
		new Insertion.Before(this.table,"<div id='"+ liveGrid.tableId+"_viewport' style='float:left;'></div>");
		this.table.previousSibling.appendChild(this.table);
		this.div = this.table.parentNode;

		this.div.style.height = (this.table.offsetHeight) + "px";
		this.div.style.width=(liveGrid.tableHeader.getWidth()+(Prototype.Browser.IE?30:16))+ "px";
		this.div.style.overflow = "hidden";
		this.topRow=0;
		this.visibleRows = liveGrid.pageSize;
	},
	_copyRows: function(rows, skip)
	{	var l= Math.min(this.visibleRows, rows.length);
		if(Prototype.Browser.IE)
		{	for (var i=0; i < l; i++)
			{	var cells=rows[i][1].split('</td>');
				var l1=(cells.length) -1;
				this.table.rows[i+skip].className=rows[i][0];
				for (var j=0; j < l1; j++) this.table.rows[i+skip].cells[j].innerHTML = cells[j].slice(4);
			}
		}
		else
		{	for (var i=0; i < l; i++)
			{	this.table.rows[i+skip].className=rows[i][0];
				this.table.rows[i+skip].innerHTML=rows[i][1];
			}
		}
		return rows.length;
	},
	refreshContents: function(startPos) {
		if(this.topRow != startPos) return;
		var rows = this.buffer.getRows(startPos, this.visibleRows ); 
		if(!rows || this._copyRows(rows,0) < this.visibleRows)
			 setTimeout(this.refreshContents.bind(this, startPos), 200);
		else this.liveGrid.options.onRefreshComplete();
	},

	scrollToPixel: function(pixelOffset) {		
		this.topRow= Math.ceil( (pixelOffset) / this.rowHeight );
		this.refreshContents(this.topRow);
	},
	getElementsComputedStyle: function ( htmlElement, cssProperty, mozillaEquivalentCSS) {
		if ( arguments.length == 2 ) mozillaEquivalentCSS = cssProperty;
		var el = $(htmlElement);
		if ( el.currentStyle ) return el.currentStyle[cssProperty];
		else return document.defaultView.getComputedStyle(el, null).getPropertyValue(mozillaEquivalentCSS);
	},
	
	visibleHeight: function() {
		return parseInt(this.getElementsComputedStyle(this.div, 'height'));
	}

};



// LiveGrid -----------------------------------------------------

LiveGrid = Class.create();

LiveGrid.prototype = {

	initialize: function( tableId, visibleRows, totalRows, url, options, ajaxOptions ) {

		this.options = {
			scrollerBorderRight: '1px solid #ababab',
			onRefreshComplete:	 Prototype.emptyFunction
		};
		Object.extend(this.options, options || {});

		this.uri=url;
		this.ajaxOptions = {parameters: null};
		Object.extend(this.ajaxOptions, ajaxOptions || {});

		this.pageSize= visibleRows;
		this.totalRows = totalRows;
		this.bufferChunkSize=this.pageSize*4;	// read 4 pages ahead. must be at least one bigger than this.pageSize

		this.tableId	  = tableId; 
		this.table		= $(tableId);

		this.tableHeader= $(this.tableId+'_header');

		this.buffer	  = new LiveGridBuffer(this);
		this.viewPort = new GridViewPort(this);

		var offset=0;
		if ( this.options.prefetchOffset >= 0)  offset = this.options.prefetchOffset;
		this.scroller = new LiveGridScroller(this, offset);
	}
};

