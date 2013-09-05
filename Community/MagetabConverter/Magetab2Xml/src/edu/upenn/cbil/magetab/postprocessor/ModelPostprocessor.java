package edu.upenn.cbil.magetab.postprocessor;

import java.util.ArrayList;
import java.util.List;

import org.apache.commons.lang.StringUtils;
import org.apache.log4j.Logger;
import org.jdom2.Attribute;
import org.jdom2.Document;
import org.jdom2.Element;

import com.google.common.collect.ArrayListMultimap;
import com.google.common.collect.ListMultimap;
import com.google.common.collect.Multimap;

import edu.upenn.cbil.magetab.model.Edge;
import edu.upenn.cbil.magetab.model.Node;
import edu.upenn.cbil.magetab.model.Study;

/**
 * Postprocessor that accepts an XML document and converts it into an object graph composed of
 * a Study object and all related Node and Edge objects.  This object graph can be more easily
 * parsed to produce a biomaterials graph.
 * @author crisl
 *
 */
public class ModelPostprocessor {
  private Document document;
  public static Logger logger = Logger.getLogger(ModelPostprocessor.class);
  
  /**
   * Constructor the accepts the JDOM2 xml document
   * @param document - JDOM2 xml document
   */
  public ModelPostprocessor(Document document) {
    this.document = document;
  }
  
  /**
   * Creates and returns the complete study object based on the provided xml document.
   * @return - Study object
   */
  public Study process() {
    Study study = new Study();
    Element studyElement = document.getRootElement().getChild("idf").getChild("study");
    study.setStudyName(studyElement.getChildText("name"));
    study.setDbId(studyElement.getAttributeValue("db_id"));
    List<Element> protocolAppNodes = document.getRootElement().getChild("sdrf").getChildren("protocol_app_node");
    study.setNodes(populateNodeData(protocolAppNodes));
    List<Element> protocolApps = document.getRootElement().getChild("sdrf").getChildren("protocol_app");
    study.setEdges(populateEdgeData(protocolApps));
    return study;
  }

  /**
   * Creates a list of nodes associated with the subject study object.  Each node is populated
   * with data needed for the biomaterials graph.
   * @param protocolAppNodes - The list of JDOM2 elements representing protocol application nodes
   * in the xml document.
   * @return - List of nodes
   */
  protected List<Node> populateNodeData(List<Element> protocolAppNodes) {
    List<Node> nodes = new ArrayList<>();
    for(Element protocolAppNode : protocolAppNodes) {
      Node node = new Node();
      node.setId(protocolAppNode.getAttributeValue("id"));
      String add = protocolAppNode.getAttributeValue("addition");
      if(add != null) {
        node.setAddition(Boolean.parseBoolean(add.trim()));
      }
      node.setDbId(protocolAppNode.getAttributeValue("db_id"));
      node.setLabel(protocolAppNode.getChildText("name"));
      node.setType(protocolAppNode.getChildText("type"));
      node.setTaxon(protocolAppNode.getChildText("taxon"));
      node.setUri(protocolAppNode.getChildText("uri"));
      Element nodeCharacteristicsElement = protocolAppNode.getChild("node_characteristics");
      if(nodeCharacteristicsElement != null) {
        List<Element> charElements = nodeCharacteristicsElement.getChildren("characteristic");
        List<String> characteristics = new ArrayList<>();
        for(Element charElement : charElements) {
          String term = charElement.getChildText("ontology_term");
          if(StringUtils.isNotEmpty(term)) {
            characteristics.add(term);
          }
        }
        characteristics = characteristics.isEmpty() ? null : characteristics; 
        node.setCharacteristics(characteristics);
      }
      nodes.add(node);
    }
    return nodes;
  }
  
  /**
   * Creates a list of edges associated with the subject study object.  Each edge is populated
   * with data needed for the biomaterials graph.
   * @param protocolApps - The list of JDOM2 elements representing protocol edges in the xml
   * document.
   * @return - List of edges
   */
  protected List<Edge> populateEdgeData(List<Element> protocolApps) {
    List<Edge> edges = new ArrayList<>();
    for(Element protocolApp : protocolApps) {
      String[] inputs = protocolApp.getChildText("inputs").split(";");
      String[] outputs = protocolApp.getChildText("outputs").split(";");
      for(String input : inputs) {
        for(String output : outputs) {
          Edge edge = new Edge();
          Attribute addAttr = protocolApp.getAttribute("addition");
          if(addAttr != null) {
            edge.setAddition(Boolean.parseBoolean(addAttr.getValue()));
          }
          edge.setDbId(protocolApp.getAttributeValue("db_id"));
          edge.setFromNode(input);
          edge.setToNode(output);
          setSharedEdgeData(protocolApp, edge);
          edges.add(edge);
        }
      }
    }
    return edges;
  }
  
  /**
   * One JDOM2 protocol application element may in fact give rise to multiple edges.
   * Each those edges shares common information.  This method sets that information
   * for each edge
   * @param protocolApp - the JDOM2 element
   * @param edge - the edge object being populated
   */
  protected void setSharedEdgeData(Element protocolApp, Edge edge) {
    edge.setLabel(protocolApp.getChildText("protocol"));
    List<Element> elements = protocolApp.getChildren("protocol_app_parameters");
    String parametersList = "";
    for(Element element : elements) {
      if(StringUtils.isNotEmpty(parametersList)) {
        parametersList += ";";
      }
      parametersList += element.getText();
    }
    String[] parameters = {};
    if(StringUtils.isNotEmpty(parametersList)) {
      parameters = parametersList.split("[;!]");
    }
    ListMultimap<String,String> map = ArrayListMultimap.create();
    for(String parameter : parameters) {
      if(parameter.contains("|")) {
        String[] components = parameter.split("\\|");
        String key = components[0];
        String value = components[1];
        map.put(key,value);
        addUnits(map, edge, key);
      }
    }
    if(!map.isEmpty()) {
      edge.setParams(map);
    }
  }
  
  /**
   * Parameters involve a name, a value and possibly a unit.  Units are maintained in the IDF
   * portion of the document.  This method collects the appropriate unit, if any, and adds
   * that to a parameter map kept in each edge object.  The map is a multimap, thus allowing
   * both value and unit to be associated with the parameter type (key).
   * @param map - multimap parameter map
   * @param edge - edge to which the parameter map belongs
   * @param key - parameter type
   */
  protected void addUnits(Multimap<String,String> map, Edge edge, String key) {
    List<Element> protocols = document.getRootElement().getChild("idf").getChildren("protocol");
    for(Element protocol : protocols) {
      if(edge.getName().contains(protocol.getChildText("name"))) {
        if(protocol.getChild("protocol_parameters") != null) {
          List<Element> params = protocol.getChild("protocol_parameters").getChildren("param");
          for(Element param : params) {
            if(param.getChildText("name").equals(key)) {
              if(param.getChild("unit_type") != null && StringUtils.isNotEmpty(param.getChildText("unit_type"))) {
                map.put(key, param.getChildText("unit_type"));
                return;
              }
            }
          }
        }
      }
    }
  }
  
}
