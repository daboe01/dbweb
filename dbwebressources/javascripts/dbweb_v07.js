// Glue package 1.3.2008 by dr. boehringer
// todo:

DBWeb = Class.create();
DBWeb.prototype = {
	initialize: function(appname,sessionid,uri,timestamp) {
		this.appname=appname;
		this.sessionid=sessionid;
		this.uri=uri;
		this.timestamp=timestamp;
		this.datagrids= new Array();
		this.cms= new Array();
		this.registerWithPage();
		document.title=this.appname;
	},
	registerWithPage: function()
	{	$A(document.forms).each(function(form, i)
		{	form.onsubmit = this.submitEnriched.bind(this,form);
			$A(form.elements).each(function(elem){ this.configElementHandler (elem) }.bind(this))
		}.bind(this))
	},
	PKFromClass: function(className)
	{	var pattern = /PK_(.+?)( |$)/;
		pattern.exec(className);
		return RegExp.$1;
	},
	URIComponentsFromClass: function(className)
	{	var pk=this.PKFromClass(className);
		var pattern = /DG_(.+?)( |$)/;
		pattern.exec(className);
		var dgn=RegExp.$1;
		return "pk="+encodeURIComponent(pk)+"&dg="+dgn;
	},
	basicParams: function()
	{	return 'sid='+this.sessionid+'&pt='+this.appname;
	},
	handleReturn: function(evt, element)
	{	if(!Prototype.Browser.WebKit && element.type!= "textarea" && evt.keyCode==Event.KEY_RETURN)
			this.submitEnriched(element.form);
	},
	propagateChange: function(evt, element)
	{	this.changedForm=element.form;
	},
	saveFocus: function(evt, element)
	{	this.focusElement=element;
	},
	checkOnblur: function(evt, element)
	{	if(this.changedForm)
		{	var s=this.basicParams()+'&inplace='+encodeURIComponent( element.name)+'&value='+ encodeURIComponent(element.value)+'&forminfo='+ element.form.elements['forminfo'].value;
			if(element.id) s+='&id='+encodeURIComponent( element.id );
			new Ajax.Request(this.uri, { method: 'post', postBody: s });
			this.changedForm=null;
		}
	},
	enforceOnblur: function(evt, element)
	{	if(element != this.focusElement && this.changedForm) this.checkOnblur(evt, element);
		else this.submitEnriched(element.form);
	},	
	addHiddenField: function(form, name, val)
	{	var field = document.createElement("input");
		field.type = "hidden";
		field.name = name;
		field.value = val;
		form.appendChild(field);
	},
	enrichSubmitForm: function(form)
	{	this.addHiddenField(form, 'sid', this.sessionid);
		this.addHiddenField(form, 'pt', this.appname);
		this.addHiddenField(form, 'ts', this.timestamp);
	},
	submitEnriched: function(form)
	{	this.saveUIData();
		this.enrichSubmitForm(form);
		form.submit();
	},
	submitAction: function(confirmtext, formname)
	{	this.saveUIData();
		setTimeout(function(){
			if(confirmtext && confirm(confirmtext) || !confirmtext)
			{	var form= document.getElementsByName(formname)[0];
				if(!form)
				{	form=document.createElement('form');
					form.action=this.uri;
					form.method='post';
					this.addHiddenField(form, 'forminfo', formname);
					document.body.appendChild(form);
				}
				this.enrichSubmitForm(form);
				if(confirmtext)		// "dangerous" actions need to be ajaxed, so that they are not repeatable via page reloads
				{	this.busy();
					new Ajax.Request(this.uri, {
						method: 'post',
						postBody: Form.serialize(form),
						onSuccess: function(t)
						{	this.saveAndJumpToLocation(this.uri+"?"+ this.basicParams() );
						}.bind(this)
					})
				}
				else form.submit();	// simple actions are directly sent so that response (e.g. a PDF file) are direcly visible/ downloaded
			}
		}.bind(this), 300);		// give inplace editor some millisecs to propagate his changes before submitting
	},
	saveUIData: function ()
	{	if(this.focusElement)
			this.addHiddenField(this.focusElement.form, 'focuspath', this.focusElement.form.name+"."+ this.focusElement.name);
		var params=this.basicParams();
		var i;
		var l=this.datagrids.length;
		for(i=0; i<l; i++)
		{	var datagrid=this.datagrids[i];
			new Ajax.Request(this.uri,
			{	method: 'post', postBody: params+'&id='+ datagrid.table.id +'&ajax=3&topline='+datagrid.viewPort.topRow, asynchronous: false
			} );
		}
	},
	saveAndJumpToLocation: function (loc)
	{	this.saveUIData();
		window.location.href=loc;
	},
	saveAndLogout: function ()
	{	this.saveUIData();
		new Ajax.Request(this.uri+"?sid="+this.sessionid+"&cc=1");	// server-side clear of all session-data
		window.location.href=this.uri+"?t=login";
	},
	registerWithContextMenu: function ( )
	{	$A(this.cms).each(function(cm, i)
		{	cm.registerDocumentForSelector();
		});
	},
	submitCTXAction: function (event,confirmtext, js, a, fn, dg)
	{	var c=this.URIComponentsFromClass(event.target.className);
		var pk=this.PKFromClass(event.target.className);
		if(!(a||fn) && js) return eval(js);
		if(confirmtext && confirm(confirmtext) || !confirmtext)
		{	var url=this.basicParams()+"&"+c+"&fn="+fn;
			if(a) url+="&a="+a;
			if(confirmtext)
			{	new Ajax.Request(this.uri, { method: 'post', postBody: url, onSuccess: function(t)   {
											 this.saveAndJumpToLocation(this.uri+"?"+this.basicParams() ) }.bind(this)
										   } );
				if(js) eval(js);
			} else
			{	if(js) eval(js);
				this.saveAndJumpToLocation(this.uri+"?"+url);
			}
		}
	},
	configElementHandler: function (elem)
	{	if(elem.className.indexOf('dbweb_delayedBinding') < 0)
		{	switch(elem.type)
			{	case "text": case "textarea": case "password":
					elem.onfocus = this.saveFocus.bindAsEventListener(this,elem);
					elem.onkeyup = this.handleReturn.bindAsEventListener(this,elem);
					elem.onchange= this.propagateChange.bindAsEventListener(this,elem);
					elem.onblur  = this.checkOnblur.bindAsEventListener(this,elem);
				break;
				case "checkbox": case "select-one":
					elem.onchange= this.enforceOnblur.bindAsEventListener(this,elem);
				break;
			}
		}

	},
	configInPlaceEditing: function(elem)
	{	elem.onchange = this.submitInPlaceEditing.bindAsEventListener(this,elem);
		elem.onblur = Prototype.emptyFunction;
	},
	submitInPlaceEditing: function(evt,element)
	{	var fval=$F(element);
		switch(element.type)
		{	case "checkbox":
				if(!fval) fval="";
			break;
		}
		var s=this.basicParams()+'&inplace='+encodeURIComponent( element.name )+'&value='+ encodeURIComponent( fval ) +'&forminfo='+ element.form.elements['forminfo'].value+'&ts='+ this.timestamp;
		if(element.id) s+='&id='+encodeURIComponent( element.id );

		var opt = {
			method: 'post',
			postBody: s,
			// asynchronous: false,
			onSuccess: function(t) {
				var pair = eval("(" + t.responseText + ")");
				var e=$(pair.key);
				if(pair.refresh) this.saveAndJumpToLocation(this.uri+"?"+this.basicParams());
				if(pair.err)
				{	// show err in red styled tooltipp
					var o = e.cumulativeOffset();
					var x = o.left,
						y = o.top,
						vpDim = document.viewport.getDimensions(),
						vpOff = document.viewport.getScrollOffsets(),
						elDim = e.getDimensions(),
						elOff = {
							left: x + 'px',
							top:((y + vpOff.top + elDim.height) <= vpDim.height 
								?(y + elDim.height) : y) + 'px', 'width': elDim.width+ 'px'
					};
					var theDiv = new Element('div', { 'class': 'errortooltipp', style: 'position:absolute;' });
					theDiv.innerHTML=pair.err;
					if(pair.oldval)
					{	var clone=e.cloneNode(true);
						clone.id=null;
						clone.value=pair.oldval;
						theDiv.appendChild(clone);
					}
					$(document.body).insert(theDiv);
					theDiv.setStyle(elOff);
					setTimeout(function(theDiv)
					{	$(theDiv).hide();
					}.bind(this,theDiv), 5000);
				} switch(e.type)
				{	case "text": case "textarea": case "password":
						e.value=pair.val;
					break;
					case "checkbox": case "select-one":
						// <!> no instant feedback at the moment
					break;
				}
			}.bind(this)
		};
		new Ajax.Request(this.uri, opt);
	},
	busy: function(evt,elementname,fieldname)
	{	document.body.style.opacity=0.75;
		document.body.style.backgroundImage="url('/dbwebressources2/loader.gif')";
		document.body.style.backgroundRepeat='no-repeat'; 
		document.body.style.backgroundAttachment='fixed'; 
		document.body.style.backgroundPosition='center center'; 
		document.body.style.color='#000000';
	},
	J: function (elem)
	{	var c=this.URIComponentsFromClass(elem.className);
		this.saveAndJumpToLocation(this.uri+"?"+this.basicParams()+"&a=select&"+c);
	},
	L: function (app,pk,dgn)
	{	this.busy();
		this.saveAndJumpToLocation(this.uri+"?sid="+this.sessionid+"&t="+app+"&a=select&pk="+encodeURIComponent(pk)+"&dg="+dgn+"&cs=1");
	},
	S: function (app)
	{	this.busy();
		this.saveAndJumpToLocation(this.uri+"?sid="+this.sessionid+"&first=1&t="+app);
	}
};
