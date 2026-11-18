from pathlib import Path
from html.parser import HTMLParser
import nh3
import tinycss2
import cssselect2
import html5lib
from app.security.file_validator import validate_ooxml


def inspect_office(path: Path):
    validate_ooxml(path, path.suffix.lstrip('.'))


STYLE_PROPERTIES={'color','background-color','font-family','font-size','font-weight','font-style','text-align',
    'text-decoration','line-height','letter-spacing','white-space','display','width','height','max-width','min-width',
    'margin','margin-left','margin-right','margin-top','margin-bottom','padding','padding-left','padding-right',
    'padding-top','padding-bottom','border','border-collapse','border-spacing','border-width','border-style','border-color',
    'vertical-align','page-break-before','page-break-after','page-break-inside','break-before','break-after','break-inside',
    'list-style-type','text-indent','float','clear','position','top','left','right','bottom','box-sizing',
    'flex','flex-direction','flex-wrap','align-items','align-content','justify-content','gap','row-gap','column-gap',
    'grid-template-columns','grid-template-rows','grid-column','grid-row','column-count','column-width'}


class Styles(HTMLParser):
    def __init__(self):
        super().__init__();self.active=False;self.rules=[];self.body_attributes={}
    def handle_starttag(self,tag,attrs):
        self.active=tag=='style' or self.active
        if tag=='body':
            self.body_attributes={name:value for name,value in attrs if name in {'style','class','id'} and value is not None}
    def handle_endtag(self,tag):
        if tag=='style':
            self.active=False
    def handle_data(self,data):
        if self.active:
            self.rules.append(data)


def sanitized_html(source: str) -> str:
    if len(source)>2_000_000:
        raise ValueError('HTML preprocessing limit exceeded')
    styles=Styles();styles.feed(source)
    if sum(len(rule) for rule in styles.rules)>64000:
        raise ValueError('Stylesheet size limit exceeded')
    clean=nh3.clean(source, tags={'p','br','div','span','h1','h2','h3','h4','h5','h6',
        'table','thead','tbody','tr','th','td','ul','ol','li','b','strong','i','em','u','pre',
        'code','blockquote','hr','sup','sub'}, attributes={'*':{'style','id','class'},'td': {'colspan','rowspan'},
        'th': {'colspan','rowspan'}}, clean_content_tags={'script','style','iframe','object','embed'},
        filter_style_properties=STYLE_PROPERTIES,url_schemes=set(), strip_comments=True)
    matcher=cssselect2.Matcher()
    for selector in cssselect2.compile_selector_list('body'):
        matcher.add_selector(selector,'margin:8px')
    rules=tinycss2.parse_stylesheet(''.join(styles.rules),skip_comments=True,skip_whitespace=True)
    if len(rules)>200:
        raise ValueError('CSS rule limit exceeded')
    for rule in rules:
        if rule.type!='qualified-rule':
            continue
        declarations=tinycss2.serialize(rule.content)
        try:
            selectors=cssselect2.compile_selector_list(tinycss2.serialize(rule.prelude))
        except cssselect2.SelectorError:
            continue
        for selector in selectors:
            if selector.pseudo_element is None:
                matcher.add_selector(selector,declarations)
    fragment=html5lib.parseFragment(clean,treebuilder='etree')
    fragment.tag='{http://www.w3.org/1999/xhtml}body'
    fragment.attrib.update(styles.body_attributes)
    root=cssselect2.ElementWrapper.from_html_root(fragment)
    for index,element in enumerate(root.iter_subtree()):
        if index>10000:
            raise ValueError('HTML element count exceeded')
        declarations=[item[3] for item in matcher.match(element)]
        declarations.append(element.etree_element.attrib.get('style',''))
        element.etree_element.set('style',';'.join(declarations))
    fragment.tag='{http://www.w3.org/1999/xhtml}div'
    rendered=html5lib.serialize(fragment,tree='etree',quote_attr_values='always',omit_optional_tags=False)
    # The final pass filters stylesheet declarations after inlining as well.
    return nh3.clean(rendered,tags={'p','br','div','span','h1','h2','h3','h4','h5','h6','table','thead','tbody','tr','th','td',
        'ul','ol','li','b','strong','i','em','u','pre','code','blockquote','hr','sup','sub'},
        attributes={'*':{'style'},'td':{'colspan','rowspan'},'th':{'colspan','rowspan'}},
        filter_style_properties=STYLE_PROPERTIES,url_schemes=set(),strip_comments=True)


async def block_network(route):
    # No remote assets are necessary after sanitization; block every scheme and
    # host rather than relying on DNS resolution susceptible to rebinding.
    await route.abort('blockedbyclient')
