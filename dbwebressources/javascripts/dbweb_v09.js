// DBWeb Glue package 18.9.2008 full-ajax version by dr. boehringer
// todo:
//	make detection of write-collisions work again (old inplace stuff)

DBWeb = Class.create();
DBWeb.prototype = {
	initialize: function(appname,sessionid,uri,adduri) {
		this.sessionid=sessionid;
		this.uri=uri;
		this.appname=appname;
		this.datagrids= new Array();
		this.toprows= new Hash();
		this.focuspath='';
		this.userscripts=null;
		this.alertOnLeave=false;
		this.page_curry=1;
		this.kbdEvent = (Prototype.Browser.Gecko || Prototype.Browser.Opera) ? "keypress" : "keydown";
		this.modalPanel=null;

		new Ajax.Request(this.uri, {
			method: 'post',
			asynchronous: true,
			postBody:this.basicParams()+"&ajax=7&first=1"+adduri,
			onSuccess: function(t){	this._reboot(t.responseText) }.bind(this)
		});
	},
	_reboot: function (t)
	{	var pairs = eval("(" + t + ")");
		if(pairs.redir_loc)
		{
			window.location.href=pairs.redir_loc;
	//		setTimeout(function(loc){window.location.href=loc;}.bind(this,pairs.redir_loc), 1000);
			return;
		}
		try {
			document.body.innerHTML=pairs.page;	// actuall ajax magic is taking place here...
			if(pairs.scripts) this.userscripts=eval("("+pairs.scripts+")");
			this.appname=pairs.appname
			document.title=this.appname;
		} catch (error){
			alert(error.description);
		};

		this.page_curry++;
		$A(document.forms).each(function(form, i)
		{	if(form.className.indexOf('DBW_noajax') < 0)
				Event.observe(form, 'submit', this.submitHandler.bindAsEventListener(this,form));
			$A(form.elements).each(function(elem){ this._configElementHandler (elem) }.bind(this))
		}.bind(this));

		for ( var id in pairs['jsconfig']['autocomplete'] )
		{	if( $(id) != null ) // <!>hasOwnProperty
			{	var d=pairs['jsconfig']['autocomplete'][id];
				var props={noPulldown:false, visibleHeight:160, paramName: "fieldvalue", frequency:0.05, minChars:2, afterClickElement: function(elem, selection) { dbweb.submitEnriched(elem.form) } };
				if(d['nopulldown']) props.noPulldown=true;
				new ComboBoxAutocompleter(id, this.uri+"?"+this.basicParams()+"&ajax=1&dg="+d['dg']+"&filter="+d['filter']+"&field="+d['field']+"&pk="+d['pk'], props);
			}
		}
		$$('.dropdown-toggle').invoke('observe',  'click', function(e){
			var o=$(e.target).up(1);
			if(o.hasClassName('open')) o.removeClassName('open');
			else(o.addClassName('open'));
			e.stop();
		}.bind(this));


		this.cms= new Array();
		this.datagrids= new Array();

		for ( var id in pairs['jsconfig']['tables'] )
		{	if( $(id)!=null)    // <!>hasOwnProperty
			{	var d=pairs['jsconfig']['tables'][id];
				var toprow=0;
				if(this.toprows.get(id) != undefined) toprow=parseInt(this.toprows.get(id));
				var dg=new LiveGrid(id, parseInt(d['rows']), parseInt(d['totalrows']), this.uri, { prefetchOffset: toprow, onRefreshComplete: this.reregisterDOMWithDBWeb.bind(this), request:this.basicParams()+"&ajax=2&dg="+d['dg']+"&filter="+d['filter']} )
				this.datagrids.push(dg);
			}
		}
		$$(".datatable").invoke("observe", "contextmenu", function(e){e.stop()}.bind(this));
		for ( var id in pairs['jsconfig']['contextmenu'] )
		{	var d=pairs['jsconfig']['contextmenu'][id]; // <!>hasOwnProperty
			this.cms.push(new Proto.Menu({selector: '.'+d['selector'], className: 'menu desktop',
				menuItems: eval("(" + d['items'] + ")")}));
		}
        Event.observe(window, 'beforeunload', function(e)
		{	if (this.alertOnLeave)
			{	this.alertOnLeave=false;
				this.enforceClick(e, this.focusElement);
			}
		}.bindAsEventListener(this));

		new HotKey('s',function(event){
			if (this.alertOnLeave)
			{	this.alertOnLeave=false;
				this.enforceClick(event, this.focusElement);
			}
			event.stop();
		}.bindAsEventListener(this));

		try {
			for ( var id in pairs['jsconfig']['userscripts'] ) eval(id);    // <!>hasOwnProperty
			eval('document.'+this.focuspath+'.select();');
		} catch (error){
		};
	},
	ajaxwatcher: function(token, curry, pe)
	{
		if(curry!=this.page_curry) pe.stop();
		else
		{
			var s=this.basicParams()+'&pf='+encodeURIComponent( token );
			new Ajax.Request(this.uri, { method: 'post', postBody: s, asynchronous: true,
				onSuccess: function(t)
						{	var pairs = eval("(" + t.responseText + ")");
							if(pairs['exists'])
							{	pe.stop();
								if(pairs['exec']) eval(pairs['exec']);
								else this.reloadPage();
							}
						}.bind(this)
					});


			}
	},
	form_autosel: function(form_id)
	{	setTimeout(function(theE)
		{	if(theE) theE.select();
		}.bind(this,$$('#'+form_id+' input[type="text"]')[0]), 100);
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
	{	var iefix='';
		if(Prototype.Browser.IE)
		{	var d = new Date();
			var time = d.getTime();
			iefix='&iefix='+time;
		}
		return 'sid='+this.sessionid+'&pt='+this.appname+iefix;
	},
	_numberOfTextfieldsInForm: function(form)	//<!>:   $$('#'+form_id+' input[type="text"]').length + $$('#'+form_id+' input[type="text"]').length
	{	var ret=0;
		var l=form.elements.length;
		for(var i=0; i < l; i++)
		{	switch(form.elements[i].type)
			{	case "text": case "password":
					ret++;
				break;
			}
		}
		return ret;
	},
	sortable: function(dgn, name)
	{	new Ajax.Request(this.uri,
			{	method: 'post', postBody: this.basicParams()+'&dg='+dgn +'&ajax=9&name='+name, asynchronous: false
			} );
		this.reloadPage();

	},
	handleReturn: function(evt, element, curry)	// firefox fix
	{	this.alertOnLeave=true;

		if( (!Prototype.Browser.WebKit || navigator.userAgent.match(/AppleWebKit\/(\d+)/)[1] >= 533) &&
			 element.type!= "textarea" && evt.keyCode==Event.KEY_RETURN)
			if( this._numberOfTextfieldsInForm(element.form) > 1 ) 
				this.submitEnriched(element.form);
	},
	propagateChange: function(evt, element, curry)
	{	this.changedForm=element.form;
	},
	saveFocus: function(evt, element, curry)
	{	this.focusElement=element;
	},
	checkOnblur: function(evt, element, curry)
	{	this.alertOnLeave=false;
		if(this.changedForm)
		{	var fval=$F(element);
			switch(element.type)
			{	case "checkbox":
					if(!fval) fval="";
				break;
			}
			var s=this.basicParams()+'&ajax=7&inplace='+encodeURIComponent( element.name)+'&value='+ encodeURIComponent(fval)+'&forminfo='+ element.form.elements['forminfo'].value;
			if(element.id) s+='&id='+encodeURIComponent( element.id );
			new Ajax.Request(this.uri, { method: 'post', postBody: s,
					onSuccess: function(t)
								{	var pairs = eval("(" + t.responseText + ")");
									for ( var id in pairs['jsconfig']['userscripts'] ) eval(id);    // <!>hasOwnProperty
									if(pairs.reload)
									{	this._reboot(t.responseText);
										if(pairs.id) $(pairs.id).select();
									} else {
										var pattern = /([^_]+)_([^_]+)_/;
										pattern.exec(pairs.inplace.key);
										var sel='.DG_'+RegExp.$1+'.PK_'+pairs.inplace.pk+' a';
										var field=RegExp.$2;
										if(curry==this.page_curry && pairs.hasOwnProperty('inplace') && pairs.inplace.hasOwnProperty('val'))
										{	$$(sel).each(function(newval,fld, a){
												if (a.className.indexOf (fld) >= 0)
												{	a.innerHTML=newval;
												}
											}.bind(this, pairs.inplace.val, 'FLD_'+field));
											var e=$(pairs.inplace.key);
											//<!> catch writeconflicts as in old version
											switch(e.type)
											{	case "text": case "textarea": case "password":
													e.value=pairs.inplace.val;
												break;
												case "checkbox": case "select-one":
													// <!> no instant feedback at the moment
												break;
											}
										}
									}
								}.bind(this)
				});
			this.changedForm=null;
		}
	},
	enforceClick: function(evt, element)
	{	if(element.className.indexOf('DBW_inplace') >= 0)
		{	this.changedForm=element.form;
			this.checkOnblur(evt, element);
		} else
		{	this.submitEnriched(element.form);
		}
	},	
	addHiddenField: function(form, name, val)
	{	var field = document.createElement("input");
		field.type = "hidden";
		field.name = name;
		field.value = val;
		form.appendChild(field);
	},
	enrichSubmitForm: function(form)
	{	this.addHiddenField(form, 'sid',this.sessionid);
		this.addHiddenField(form, 'pt',	this.appname);
	},
	submitHandler: function(event, form)
	{	event.stop();
		this.submitEnriched(form);
	},
	submitEnriched: function(form)
	{	this.submitEnrichedAsync(form, false);
	},
	submitEnrichedAsync: function(form, async)
	{	this.alertOnLeave=false;
		this.saveUIData();
		this.enrichSubmitForm(form);

		new Ajax.Request(this.uri, {
					method: 'post',
					asynchronous: async,
					postBody: Form.serialize(form)+'&ajax=7',
					onSuccess: function(t)
					{	this.changedForm=null;
						this._reboot(t.responseText);
					}.bind(this)});
	},
    reloadPage: function(){
        new Ajax.Request(this.uri,
            {   method: 'post',
                postBody: this.basicParams()+"&ajax=10",
                asynchronous: false,
                onSuccess: function(t)
                {   this._reboot(t.responseText);
                }.bind(this)
            });
	},

	submitFileUpload: function(event, elem){
		event.stop();
        var xhr=Ajax.getTransport();
		// modern style upload available?
        if(xhr && ( xhr.upload || xhr.sendAsBinary ) )
        {   xhr.open("post", this.uri+"?"+this.basicParams()+'&ajax=8&forminfo='+ elem.form.elements['forminfo'].value, true);
            xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
            var feedback=function(e){
					var theDiv = new Element('div', { 'class': 'successtooltipp', style: 'position:absolute;' });
					theDiv.innerHTML="Upload completed";
					$(document.body).insert(theDiv);
					var o = e.cumulativeOffset();
					theDiv.setStyle({ left: o.left + 'px', top: o.top+20 + 'px'});
					setTimeout(function(theDiv)
					{//	 $(theDiv).hide();
					 //	 e.value='';
                        this.reloadPage();
					}.bind(this,theDiv,e), 1000);
            }
			xhr.upload.onload=feedback.bind(this,elem);
			// the actual upload step has to be adapted to browser capabilities....
            var fileelem=(elem.files || [elem])[0];
            if(fileelem.getAsBinary)    //FF3
            {	var multipart = function(boundary, name, file){
                return  "--".concat(
						boundary, CRLF,
						'Content-Disposition: form-data; name="', name, '"; filename="', file.fileName, '"', CRLF,
						"Content-Type: application/octet-stream", CRLF,
						CRLF, file.getAsBinary(), CRLF, "--", boundary, "--", CRLF
					);
				}, CRLF    = "\r\n";
				var boundary = "AjaxUploadBoundary" + (new Date).getTime();
				xhr.setRequestHeader("Content-Type", "multipart/form-data; boundary=" + boundary);
                xhr[xhr.sendAsBinary ? "sendAsBinary" : "send"](multipart(boundary, elem.name, fileelem));
            }
            else    // Safari4
            {	xhr.setRequestHeader("Content-Type", "application/octet-stream");
                xhr.setRequestHeader("X-Name", elem.name);
                xhr.setRequestHeader("X-Filename", elem.value);
                xhr.send(elem.files[0]);
            }
        } else	// traditional style upload via hidden iframe (eg. IE).
        {   this.enrichSubmitForm(elem.form);
            this.addHiddenField(elem.form, 'ajax', '8');

            var idframename = '_hiddeniframe_';
            // create iframe, so we dont need to refresh page
            var iframe = new Element('iframe', { name: idframename });
            iframe.setStyle({ display: 'none' });
            $(document.body).insert(iframe);
            elem.form.target=idframename;
            elem.form.submit();
            elem.value='';
            iframe.remove();			
        }
	},
	submitAction: function(confirmtext, formname, noajax, progress, button)
	{	if(progress>0)
		{	this.blockPageUI();
			var elem= new Element('div');
			if(!noajax) button.disabled=true;
			$(button).insert( {after: elem} );
			new ProgressBar(elem, 100, progress);
		}
		setTimeout(function(){
			if(confirmtext && confirm(confirmtext) || !confirmtext)
			{	if(noajax) window.location.href=this.uri+"?"+this.basicParams()+"&ajax=0&forminfo="+formname;
				else
				{	var form= document.getElementsByName(formname)[0];
					if(!form)
					{	form=document.createElement('form');
						form.action=this.uri;
						form.method='post';
						this.addHiddenField(form, 'forminfo', formname);
						document.body.appendChild(form);
					}
					this.submitEnrichedAsync(form, progress>0);
				}
			}
		}.bind(this), 300);		// give inplace editor some millisecs to propagate his changes before submitting
	},
	submitCTXAction: function (event, confirmtext, js, a, fn, dg)
	{	var c=this.URIComponentsFromClass(Event.findElement(event,'tr').className);
		//var c=this.URIComponentsFromClass(event.target.className);
		var pk=this.PKFromClass(event.target.className);
		if(!(a||fn) && js) return eval(js);
		if(confirmtext && confirm(confirmtext) || !confirmtext)
		{	var url=this.basicParams()+"&ajax=7&"+c+"&fn="+fn;
			if(a) url+="&a="+a;
			new Ajax.Request(this.uri, { method: 'post', postBody: url, onSuccess: function(t) { this._reboot(t.responseText) }.bind(this) } );
			try {
				if(js) eval(js);
			} catch (error){
				alert(error.description);
			};
		}
	},
	raiseDOMID: function (event, id)
	{	this.submitCTXAction(event, null, null,'select');
		this.reloadPage();
		setTimeout(function(event,id){
			$(id).setStyle({left:Event.pointer(event).x+'px', top: Event.pointer(event).y+'px'}).appear({duration:0.15});
			this.modalPanel=id;
			Event.observe(document, this.kbdEvent, this.kbdObserver);
			this.form_autosel(id);
		}.bind(this,event,id), 300);		// give inplace editor some millisecs to propagate his changes before submitting
	},
	kbdObserver:function (event)
	{
		switch(event.keyCode) {
			case Event.KEY_ESC:
			if(dbweb.modalPanel)
			{
				$(dbweb.modalPanel).fade({duration:0.15});
				dbweb.modalPanel=null;
				Event.stopObserving(document, dbweb.kbdEvent, dbweb.kbdObserver);
			}
			break;
		}
	},
	saveUIData: function ()
	{	if(this.focusElement && this.focusElement.form)
		{	this.focuspath=this.focusElement.form.name+"."+ this.focusElement.name;
			this.addHiddenField(this.focusElement.form, 'focuspath', this.focuspath);
		}
		var params=this.basicParams();
		var i;
		var l=this.datagrids.length;
		for(i=0; i<l; i++)
		{	var datagrid=this.datagrids[i];
			this.toprows.set(datagrid.tableId, datagrid.viewPort.topRow);
			new Ajax.Request(this.uri,
			{	method: 'post', postBody: params+'&id='+ datagrid.table.id +'&ajax=3&topline='+datagrid.viewPort.topRow, asynchronous: false
			} );
		}
	},
	saveAndJumpToLocation: function (loc, noajax)
	{	this.saveUIData();
		if(!noajax)
			new Ajax.Request(loc+"&ajax=7", {
				method: 'get',
				asynchronous: false,
				onSuccess: function(t) { this._reboot(t.responseText) }.bind(this) });
		else window.location.href=loc;
	},
	saveAndLogout: function ()
	{	this.saveUIData();
		new Ajax.Request(this.uri+"?sid="+this.sessionid+"&cc=1&ajax=7", {
				method: 'get',
				asynchronous: false,
				onSuccess: function(t)
				{	document.body.innerHTML="<h1> Page logged out </h1>";
					this._reboot(t.responseText);
				}.bind(this) });
	},
	reregisterDOMWithDBWeb: function ( )
	{	$A(this.cms).each(function(cm, i)
		{	cm.registerDocumentForSelector();
		});
	},
	_configElementHandler: function (elem)
	{	if(elem.className.indexOf('dbweb_delayedBinding') < 0)
		{	switch(elem.type)
			{	case "text": case "textarea": case "password":
					Event.observe(elem, 'focus', this.saveFocus.bindAsEventListener(this,elem, this.page_curry));
					Event.observe(elem, 'keyup', this.handleReturn.bindAsEventListener(this,elem, this.page_curry));
					Event.observe(elem, 'change',this.propagateChange.bindAsEventListener(this,elem, this.page_curry));
					Event.observe(elem, 'blur',  this.checkOnblur.bindAsEventListener(this,elem, this.page_curry));
				break;
				case "checkbox": case "select-one":
					Event.observe(elem, 'change', this.enforceClick.bindAsEventListener(this,elem));
				break;
				case "file":
                    if(!Prototype.Browser.IE) elem.setAttribute("multiple", "true");
					Event.observe(elem, 'change', this.submitFileUpload.bindAsEventListener(this, elem));
				break;
			}
		} else
		{	Event.observe(elem, 'change', this.checkOnblur.bindAsEventListener(this,elem));
		}
	},
	blockPageUI: function(evt,elementname,fieldname)
	{	var blurDiv = document.createElement("div");
		blurDiv.style.cssText = "position:absolute; top:0; right:0; width:" + screen.width + "px; height:" + screen.height + "px; background-color: #FFFFFF; opacity:0.5; filter:alpha(opacity=50)";
		document.body.appendChild(blurDiv);
	},
	J: function(event)
	{	var cn=(Event.findElement(event,'tr') || Event.findElement(event,'li')).className;
		if( cn.indexOf('_')<0)
			cn=(Event.findElement(event,'td')).className;
		var c=this.URIComponentsFromClass(cn);
		this.saveAndJumpToLocation(this.uri+"?"+this.basicParams()+"&a=select&"+c, false);
	},
	L: function (app,pk,dgn)
	{	this.saveAndJumpToLocation(this.uri+"?sid="+this.sessionid+"&t="+app+"&a=select&pk="+encodeURIComponent(pk)+"&dg="+dgn+"&cs=1", true);
	},
	S: function (app)
	{	this.saveAndJumpToLocation(this.uri+"?sid="+this.sessionid+"&t="+app, true);
	}
};
